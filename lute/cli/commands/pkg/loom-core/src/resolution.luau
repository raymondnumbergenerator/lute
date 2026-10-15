local fs = require("@std/fs")
local github = require("./github")
local lockfile = require("./lockfile")
local path = require("@std/path")
local pp = require("@batteries/pp")
local manifest = require("./manifest")
local registry = require("./registry")
local registryUrlUtil = require("./registryurl")
local semver = require("./semver")
local store = require("./store")

--[[
Workspaces as virtual packages (prototype)

There is no workspace concept in the resolver. A repository groups its packages
with a *virtual package*: a `package` without `name`/`version` whose path
dependencies are the packages it groups (its members). Installing from the
virtual root runs the ordinary resolution below, so every member ends up in one
lockfile and one solved set of registry versions. The additions for this are:

  * Members (`getMemberKeys`): the direct path dependencies of a virtual root.
    Only the root's and the members' development dependencies are resolved.
    This is decided by the manifest alone, so the lockfile never depends on
    how `install` was invoked (beyond `--exclude-dev`, which only omits them).
  * Source packages (`SourceLocation`): path and GitHub dependencies are the
    same thing, a fetched source root plus a package directory inside it. A
    virtual package cannot be depended on, so a consumer points at one
    member's directory, with a path or with a GitHub `target` such as
    "modules/apple". See the section comment above `locateSourcePackage`.
  * Path versions (`checkPathVersion`): a path dependency may carry a semver
    `version` that the target package must satisfy, checked on every edge.
  * Path resolution at parse time (`PathDependencySpec.directory`): every path
    dependency and path override carries an absolute directory, so a sibling's
    `../apple` and the root's `./modules/apple` are the same package without
    the resolver normalizing anything.
  * Version 4 lockfiles (`buildLockfile`): development aliases are written to
    separate `devDependencies` maps at the root and on member records.

Freshness (`tryReuseLockfile`, `pathDepsAreStale`) mirrors each of these: a
lock is reused only if path versions, GitHub targets, and member development
dependencies still match the manifests.
]]

local function getManifestPath(directory: string): string
	return `{directory}/loom.config.luau`
end

local function getLockfilePath(directory: string): string
	return `{directory}/loom.lock.luau`
end

local function getKey(spec: manifest.DependencySpec): string
	if spec.sourceKind == "github" then
		return `{spec.name}@{spec.rev}`
	end

	return spec.name
end

local function hasConflict(
	resolved: lockfile.LockfileDependency,
	incoming: manifest.DependencySpec,
	rootDirectory: string
): boolean
	return not lockfile.isSameSource(resolved, incoming, rootDirectory)
end

--[[
Source packages: a fetched source root plus a package directory

Path and GitHub dependencies differ only in how their source root is obtained:
a local directory is used in place, and a GitHub repository is checked out once
per repository and revision into the store. Either way, a package is a
directory inside that root (the root itself for a path dependency, the checkout
joined with `target` for GitHub), and everything after fetching works on that
pair instead of branching on the source kind:

  * `locateSourcePackage` fetches the root and returns the package directory.
  * Path dependencies are resolved against the declaring manifest when it is
    parsed. `resolveDependencySource` keeps one inside a checkout in that
    source: it becomes the same repository and revision with another `target`.
  * `getInstallPath` writes the package directory relative to the install root
    for local sources and to the store for checkouts.
  * `lockfile.isSameSource` compares (sourceKind, source, rev, target) for
    conflict and freshness checks alike.

The one asymmetry is the boundary: a checkout is self-contained, so a path that
leaves it is an error, while a local path may point anywhere on disk (such as
`../somewhere/shared`).
]]

-- Where a source package's code lives. `checkout` is set for GitHub sources:
-- the shared checkout root, and the spec it was fetched for, which path
-- dependencies inside the checkout inherit.
type SourceLocation = {
	read directory: string,
	read checkout: { read root: string, read spec: manifest.GitHubDependencySpec }?,
}

-- Keeps a dependency declared by the package at `from` in that package's
-- source. A path inside a GitHub checkout becomes the same repository and
-- revision with the sibling's directory as `target`, so the lockfile records a
-- portable source instead of a store path; a path that leaves the checkout is
-- an error. Local paths need nothing: the parser already resolved them.
local function resolveDependencySource(spec: manifest.DependencySpec, from: SourceLocation): manifest.DependencySpec
	local checkout = from.checkout
	if spec.sourceKind ~= "path" or checkout == nil then
		return spec
	end

	if not fs.exists(spec.directory) then
		error(`Path dependency directory not found: {spec.directory} (for package '{spec.name}')`)
	end

	local target = path.relative(checkout.root, spec.directory)
	if target.parts[1] == ".." then
		error(
			`Path dependency '{spec.name}' leaves its repository {checkout.spec.source}; use a GitHub or registry dependency instead`
		)
	end

	return table.freeze({
		name = spec.name,
		sourceKind = "github" :: "github",
		source = checkout.spec.source,
		rev = checkout.spec.rev,
		target = if #target.parts == 0 then nil else path.format(target),
	})
end

-- Returns the lockfile keys of the install root's members: the direct path
-- dependencies (from `dependencies` or `dev_dependencies`) of a virtual root.
--
-- Members are the packages being developed in this repository, so their
-- development dependencies are resolved and installed alongside the root's.
-- No other package's are: not a member's own path dependencies, not path
-- packages outside the repository, and not a named root's path dependencies,
-- which keeps single-package projects behaving as before. Listing a package in
-- the virtual root is the only way to make it a member.
--
-- Keys are computed from override-applied specs, so they match the keys
-- `resolveSourcePackage` assigns.
local function getMemberKeys(
	rootManifest: manifest.ProjectManifest,
	overrides: { [string]: manifest.DependencySpec }
): { [string]: boolean }
	local members: { [string]: boolean } = {}
	if rootManifest.package.name ~= nil then
		return members
	end

	for _, section in { rootManifest.package.dependencies, rootManifest.package.devDependencies } do
		for _, spec in section do
			if spec.sourceKind ~= "path" then
				continue
			end
			local effectiveSpec = overrides[spec.name] or spec
			if effectiveSpec.sourceKind == "path" then
				members[getKey(effectiveSpec)] = true
			end
		end
	end

	return members
end

-- Fetches a path or GitHub dependency's source root and returns where its
-- package lives. A GitHub checkout is shared by every package taken from that
-- repository and revision (see `store.getGitHubCheckoutKey`); `target` picks
-- the package directory inside it. The parser keeps `target` inside the
-- checkout; this only checks that it exists.
local function locateSourcePackage(spec: manifest.DependencySpec): SourceLocation
	if spec.sourceKind == "path" then
		if not fs.exists(spec.directory) then
			error(`Path dependency directory not found: {spec.directory} (for package '{spec.name}')`)
		end
		return { directory = spec.directory }
	elseif spec.sourceKind == "github" then
		store.ensureStoreDirectory()

		local checkoutKey = store.getGitHubCheckoutKey(spec.source, spec.rev)
		local checkoutRoot = store.getPackagePath(checkoutKey)
		if not store.hasPackage(checkoutKey) then
			github.installPackage(spec.source, spec.rev, checkoutRoot)
		end

		local directory = if spec.target then path.format(path.join(checkoutRoot, spec.target)) else checkoutRoot
		if not fs.exists(directory) then
			error(`'target' {spec.target} not found in {spec.source}@{spec.rev} (for package '{spec.name}')`)
		end
		return { directory = directory, checkout = { root = checkoutRoot, spec = spec } }
	else
		error(`Unsupported source kind: {spec.sourceKind} for package {spec.name}`)
	end
end

-- The lockfile's `installPath` for a source package: relative to the install
-- root for local sources, and `@pkg/<checkout key>/<target>` for checkouts, so
-- the lockfile never records a machine-specific store path.
local function getInstallPath(location: SourceLocation, rootDirectory: string): string
	if location.checkout then
		return store.toStorePath(path.format(path.relative(store.getStoreDirectory(), location.directory)))
	end
	return path.format(path.relative(rootDirectory, location.directory))
end

-- Returns an error message when a path dependency's optional `version`
-- requirement is not satisfied by the package it selects, or nil when it is
-- satisfied or absent.
--
-- The check runs per edge rather than per package: a package is resolved once,
-- possibly through an edge without a requirement (for example the virtual root
-- listing it), so a later edge's requirement would otherwise never be checked.
-- It also runs during lockfile reuse, because the lockfile does not record the
-- target's version. Both cost a manifest read per versioned path edge.
local function checkPathVersion(spec: manifest.DependencySpec, rootDirectory: string): string?
	if spec.sourceKind ~= "path" or spec.version == nil then
		return nil
	end

	local pkg = manifest.parseFile(getManifestPath(locateSourcePackage(spec).directory)).package
	if pkg.version == nil then
		return `Path dependency '{spec.name}' with a version requirement cannot target a virtual package`
	end

	local packageVersion = semver.tryParse(pkg.version)
	if packageVersion == nil or not semver.satisfies(packageVersion, semver.parseConstraint(spec.version)) then
		local relativePath = path.format(path.relative(rootDirectory, spec.directory))
		return `Path dependency '{spec.name}' requires version {spec.version}, but '{relativePath}' is {pkg.version}`
	end

	return nil
end

-- `checkPathVersion` for resolution, where an unsatisfied requirement is fatal.
local function assertPathVersion(spec: manifest.DependencySpec, rootDirectory: string)
	local message = checkPathVersion(spec, rootDirectory)
	if message then
		error(message)
	end
end

export type ResolveOptions = {
	read excludeDev: boolean?,
	read locked: boolean?,
}

type RootRegistryAlias = {
	read alias: string,
	read name: string,
	-- Whether the alias came from the root's dev_dependencies, which decides
	-- whether it is written to the lockfile's `dependencies` or `devDependencies`.
	read dev: boolean,
}

type ResolutionState = {
	queue: { manifest.DependencySpec },
	queueIndex: number,
	dependencies: { [string]: string },
	packages: { [string]: lockfile.LockfileDependency },
	registryRequirements: { [string]: semver.Requirement },
	-- Maps a source-qualified package identity to its name in the registry.
	registrySources: { [string]: string },
	-- Maps an unqualified registry package name to all source-qualified identities seen for it.
	registryIdentitiesBySource: { [string]: { [string]: boolean } },
	rootRegistryAliases: { RootRegistryAlias },
	unresolvedRegistryDependencies: { [string]: { [string]: string } },
	openDependencies: { [string]: { [string]: string } },
	registryUrlByPackage: { [string]: string },
	-- Development counterparts of `dependencies`, `unresolvedRegistryDependencies`,
	-- and `openDependencies`. `devDependencies` holds the root's development
	-- aliases; `openDevDependencies[key]` exists only for members (see
	-- `memberKeys`) and becomes that record's `devDependencies` map. They are
	-- kept apart so installs can exclude development dependencies from the
	-- lockfile alone, without re-reading manifests.
	devDependencies: { [string]: string },
	unresolvedRegistryDevDependencies: { [string]: { [string]: string } },
	openDevDependencies: { [string]: { [string]: string } },
	-- Keys of the virtual root's members; empty for a named root.
	memberKeys: { [string]: boolean },
}

local function getRegistryPackageName(name: string, registryUrl: string?): string
	if registryUrl == nil then
		return name
	end

	return store.qualifyRegistryKey(name, registryUrl)
end

local function registerRegistryPackage(
	registrySources: { [string]: string },
	registryIdentitiesBySource: { [string]: { [string]: boolean } },
	registryUrlByPackage: { [string]: string },
	name: string,
	registryUrl: string?
): string
	local registryPackageName = getRegistryPackageName(name, registryUrl)
	registrySources[registryPackageName] = name

	if not registryIdentitiesBySource[name] then
		registryIdentitiesBySource[name] = {}
	end
	registryIdentitiesBySource[name][registryPackageName] = true

	if registryUrl then
		registryUrlByPackage[registryPackageName] = registryUrl
	end

	return registryPackageName
end

local function getRegistryLockKey(state: ResolutionState, registryPackageName: string, version: string): string
	local source = state.registrySources[registryPackageName] or registryPackageName
	local identities = state.registryIdentitiesBySource[source]
	local identityCount = 0
	if identities then
		for _ in identities do
			identityCount += 1
		end
	end

	local packageName = if identityCount > 1 then registryPackageName else source
	return `{packageName}@{version}`
end

-- Reads a source package's manifest and queues its dependencies. Path and
-- GitHub dependencies are queued for `processSourceQueue`; registry
-- dependencies become solver requirements, filled in after solving.
--
-- The prototype passes `state` instead of each table separately, because
-- members need two more tables for their development dependencies.
-- Development dependencies are collected only when `resolveSourcePackage` has
-- opened a `devDependencies` table for this package, that is, for members.
local function collectSourcePackageDependencies(
	state: ResolutionState,
	key: string,
	location: SourceLocation,
	overrides: { [string]: manifest.DependencySpec },
	rootRegistryUrl: string?
)
	local nestedManifestPath = getManifestPath(location.directory)
	if not fs.exists(nestedManifestPath) then
		return
	end

	local dependencyManifest = manifest.parseFile(nestedManifestPath)

	-- Virtual packages only group packages; a dependency must point at one of
	-- their members instead (a path to its directory, or a GitHub `target`).
	if dependencyManifest.package.name == nil then
		error(
			`'{key}' points at a virtual package, which cannot be depended on; point at one of its packages' directories instead (for GitHub, set 'target')`
		)
	end

	-- Collects one manifest section into `transitiveDependencies` (the record's
	-- alias map) and `unresolvedRegistryDependencies` (registry aliases waiting
	-- for the solver). Shared by `dependencies` and `dev_dependencies`;
	-- requirement keys cannot collide between them because the parser rejects
	-- an alias that appears in both.
	local function collectSection(
		section: { [string]: manifest.DependencySpec },
		transitiveDependencies: { [string]: string },
		unresolvedRegistryDependencies: { [string]: { [string]: string } }
	)
		for dependencyAlias, declaredSpec in section do
			-- Inside a GitHub checkout this turns a sibling path into the same
			-- repository and revision with the sibling's `target`.
			local dependencySpec = resolveDependencySource(declaredSpec, location)
			local overrideSpec = overrides[dependencySpec.name]
			local effectiveSpec = overrideSpec or dependencySpec

			if dependencySpec.sourceKind == "registry" then
				assert(
					dependencyManifest.registry ~= nil,
					`Package '{key}' has registry dependency '{dependencySpec.name}' but no 'registry' field in its manifest.`
				)
			end

			if effectiveSpec.sourceKind == "registry" then
				local effectiveRegistryUrl = if overrideSpec then rootRegistryUrl else dependencyManifest.registry
				local registryPackageName = registerRegistryPackage(
					state.registrySources,
					state.registryIdentitiesBySource,
					state.registryUrlByPackage,
					effectiveSpec.name,
					effectiveRegistryUrl
				)

				state.registryRequirements[`{key}:{dependencyAlias}`] = {
					name = registryPackageName,
					constraint = semver.parseConstraint(effectiveSpec.version),
					requiredBy = key,
					aliasedAs = if dependencyAlias ~= effectiveSpec.name then dependencyAlias else nil,
				}

				if not unresolvedRegistryDependencies[key] then
					unresolvedRegistryDependencies[key] = {}
				end

				unresolvedRegistryDependencies[key][dependencyAlias] = registryPackageName
			else
				transitiveDependencies[dependencyAlias] = getKey(effectiveSpec)
				table.insert(state.queue, effectiveSpec)
			end
		end
	end

	collectSection(
		dependencyManifest.package.dependencies,
		state.openDependencies[key],
		state.unresolvedRegistryDependencies
	)

	if state.openDevDependencies[key] then
		collectSection(
			dependencyManifest.package.devDependencies,
			state.openDevDependencies[key],
			state.unresolvedRegistryDevDependencies
		)
	end
end

local function resolveSourcePackage(
	state: ResolutionState,
	spec: manifest.DependencySpec,
	rootDirectory: string,
	overrides: { [string]: manifest.DependencySpec },
	rootRegistryUrl: string?,
	excludeDev: boolean
): string
	local key = getKey(spec)
	local packages = state.packages

	-- Checked on every edge, before the already-resolved early return below: the
	-- package may have been resolved through another edge without a requirement.
	assertPathVersion(spec, rootDirectory)

	if packages[key] then
		if hasConflict(packages[key], spec, rootDirectory) then
			error(
				`Source mismatch for package '{spec.name}':\n`
					.. `  resolved: {packages[key].source} ({packages[key].sourceKind})\n`
					.. `  incoming: {spec.source} ({spec.sourceKind})\n`
					.. `Both resolve to '{key}' but from different sources.`
			)
		end

		return key
	end

	local transitiveDependencies: { [string]: string } = {}
	state.openDependencies[key] = transitiveDependencies

	local location = locateSourcePackage(spec)

	-- Opening a table here is what makes `collectSourcePackageDependencies`
	-- collect this package's development dependencies; see `getMemberKeys`.
	local transitiveDevDependencies: { [string]: string }? = nil
	if state.memberKeys[key] and not excludeDev then
		local devDependencies = {}
		transitiveDevDependencies = devDependencies
		state.openDevDependencies[key] = devDependencies
	end

	collectSourcePackageDependencies(state, key, location, overrides, rootRegistryUrl)

	packages[key] = table.freeze({
		name = spec.name,
		rev = if spec.sourceKind == "github" then spec.rev else nil,
		target = if spec.sourceKind == "github" then spec.target else nil,
		-- Paths are recorded relative to the install root, like `installPath`.
		source = if spec.sourceKind == "path"
			then path.format(path.relative(rootDirectory, spec.directory))
			else spec.source,
		sourceKind = spec.sourceKind,
		-- The lock key stays `name@rev` for GitHub; only the checkout is shared.
		installPath = getInstallPath(location, rootDirectory),
		dependencies = transitiveDependencies,
		devDependencies = transitiveDevDependencies,
	})

	return key
end

local function processSourceQueue(
	state: ResolutionState,
	rootDirectory: string,
	overrides: { [string]: manifest.DependencySpec },
	rootRegistryUrl: string?,
	excludeDev: boolean
)
	while state.queueIndex <= #state.queue do
		local spec = state.queue[state.queueIndex]
		state.queueIndex += 1

		resolveSourcePackage(state, spec, rootDirectory, overrides, rootRegistryUrl, excludeDev)
	end
end

local function buildEffectiveUniverse(
	universe: semver.Universe,
	overrides: { [string]: manifest.DependencySpec },
	registrySources: { [string]: string }
): (semver.Universe, { [string]: { [string]: string } })
	local registryOverrides: { [string]: semver.Constraint } = {}
	local sourceOverrideNames: { [string]: boolean } = {}
	for name, spec in overrides do
		if spec.sourceKind == "registry" then
			registryOverrides[name] = semver.parseConstraint(spec.version)
		else
			sourceOverrideNames[name] = true
		end
	end

	local effective: semver.Universe = {}
	local sourceOverridedDeps: { [string]: { [string]: string } } = {}

	for pkgName, versions in universe do
		local sourceName = registrySources[pkgName] or pkgName
		if registryOverrides[sourceName] then
			local filtered: { semver.PackageVersion } = {}
			for _, v in versions do
				if semver.satisfies(v.version, registryOverrides[sourceName]) then
					table.insert(filtered, v)
				end
			end
			assert(
				#filtered > 0,
				`Override constrains '{sourceName}' to {semver.formatConstraint(registryOverrides[sourceName])}, but no matching version exists in the registry`
			)
			effective[pkgName] = filtered
		elseif sourceOverrideNames[sourceName] then
			continue
		else
			local rewritten: { semver.PackageVersion } = {}
			for _, v in versions do
				local newDeps: { [string]: semver.Requirement } = {}
				for alias, dep in v.dependencies do
					local dependencySource = registrySources[dep.name] or dep.name
					if registryOverrides[dependencySource] then
						newDeps[alias] = table.freeze({
							name = dep.name,
							constraint = registryOverrides[dependencySource],
							requiredBy = dep.requiredBy,
							aliasedAs = dep.aliasedAs,
						})
					elseif sourceOverrideNames[dependencySource] then
						local vKey = `{v.name}@{v.versionString}`
						if not sourceOverridedDeps[vKey] then
							sourceOverridedDeps[vKey] = {}
						end
						sourceOverridedDeps[vKey][alias] = dependencySource
					else
						newDeps[alias] = dep
					end
				end
				table.insert(
					rewritten,
					table.freeze({
						name = v.name,
						version = v.version,
						versionString = v.versionString,
						dependencies = table.freeze(newDeps),
					})
				)
			end
			effective[pkgName] = rewritten
		end
	end

	return effective, sourceOverridedDeps
end

-- Compares one recorded alias map of a path package (its `dependencies` or
-- `devDependencies`) with the manifest section it was resolved from. Returns
-- true when an alias was added or removed, or when a recorded package no longer
-- matches its spec: source, GitHub target, path version, registry, or semver
-- constraint. Factored out so members' development maps get the same checks.
local function aliasesAreStale(
	lock: lockfile.Lockfile,
	recorded: { [string]: string },
	declared: { [string]: manifest.DependencySpec },
	packageInstallPath: string,
	rootDirectory: string,
	overrides: { [string]: manifest.DependencySpec },
	rootRegistryUrl: string?,
	packageRegistryUrl: string?
): boolean
	for alias in declared do
		if recorded[alias] == nil then
			return true
		end
	end

	for alias in recorded do
		if declared[alias] == nil then
			return true
		end
	end

	for alias, depSpec in declared do
		if depSpec.sourceKind == "path" and not fs.exists(depSpec.directory) then
			return true
		end
		local overrideSpec = overrides[depSpec.name]
		depSpec = overrideSpec or depSpec

		local recordedPkg = lock.packages[recorded[alias]]
		if recordedPkg == nil then
			return true
		end
		if not lockfile.isSameSource(recordedPkg, depSpec, rootDirectory) then
			return true
		end
		if depSpec.sourceKind == "path" then
			local versionOk, versionError = pcall(checkPathVersion, depSpec, rootDirectory)
			if not versionOk or versionError ~= nil then
				return true
			end
		elseif depSpec.sourceKind == "registry" then
			local registryUrl = if overrideSpec then rootRegistryUrl else packageRegistryUrl
			if not registryUrlUtil.equals(recordedPkg.registry, registryUrl) then
				return true
			end

			local constraint = semver.parseConstraint(depSpec.version)
			local lockedVersion = semver.tryParse(recordedPkg.rev :: string)
			if lockedVersion == nil or not semver.satisfies(lockedVersion, constraint) then
				return true
			end
		end
	end

	return false
end

local function pathDepsAreStale(
	lock: lockfile.Lockfile,
	rootDirectory: string,
	overrides: { [string]: manifest.DependencySpec },
	rootRegistryUrl: string?,
	excludeDev: boolean,
	memberKeys: { [string]: boolean }
): boolean
	for key, pkg in lock.packages do
		if pkg.sourceKind ~= "path" then
			continue
		end

		local packageInstallPath = path.format(path.join(rootDirectory, pkg.installPath))

		local depManifestPath = getManifestPath(packageInstallPath)
		if not fs.exists(depManifestPath) then
			return true
		end

		local ok, depManifest = pcall(manifest.parseFile, depManifestPath)
		if not ok then
			return true
		end

		if
			aliasesAreStale(
				lock,
				pkg.dependencies,
				depManifest.package.dependencies,
				packageInstallPath,
				rootDirectory,
				overrides,
				rootRegistryUrl,
				depManifest.registry
			)
		then
			return true
		end

		-- Members also record development dependencies; compare those unless they
		-- are excluded. A lock written with --exclude-dev has no member dev maps,
		-- so a later full install sees them as missing and re-resolves.
		if
			not excludeDev
			and memberKeys[key]
			and aliasesAreStale(
				lock,
				pkg.devDependencies or {},
				depManifest.package.devDependencies,
				packageInstallPath,
				rootDirectory,
				overrides,
				rootRegistryUrl,
				depManifest.registry
			)
		then
			return true
		end
	end
	return false
end

local function tryReuseLockfile(
	rootManifest: manifest.ProjectManifest,
	lockfilePath: string,
	rootDirectory: string,
	excludeDev: boolean,
	options: ResolveOptions?
): (lockfile.Lockfile?, { [string]: string }?)
	local overrides = rootManifest.overrides
	local existingLock = lockfile.tryParseFile(lockfilePath)

	if options and options.locked and existingLock == nil then
		error("--locked: no lockfile found. Run `lute pkg install` first.")
	end

	if existingLock then
		local satisfied, reason = lockfile.satisfiesManifest(existingLock, rootManifest, rootDirectory, excludeDev)

		if options and options.locked then
			if not satisfied then
				error(`--locked: lockfile does not satisfy manifest ({reason}). Run \`lute pkg install\` to update.`)
			end
			return existingLock, nil
		end

		-- Root path dependencies with a version requirement are checked against
		-- the packages they select, which the lockfile does not record. Transitive
		-- path edges get the same check in `aliasesAreStale`.
		if satisfied then
			for _, section in { rootManifest.package.dependencies, rootManifest.package.devDependencies } do
				for _, spec in section do
					local versionOk, versionError = pcall(checkPathVersion, spec, rootDirectory)
					if not versionOk or versionError ~= nil then
						satisfied = false
					end
				end
			end
		end

		if
			satisfied
			and not pathDepsAreStale(
				existingLock,
				rootDirectory,
				overrides,
				rootManifest.registry,
				excludeDev,
				getMemberKeys(rootManifest, overrides)
			)
		then
			return existingLock, nil
		end
	end

	-- Extract locked registry versions for soft preference during re-resolution.
	-- Skip packages that were previously overridden — removing an override should unlock the version.
	local lockedRegistryVersions: { [string]: string }? = nil
	if existingLock then
		lockedRegistryVersions = {}
		local previousOverrides = existingLock.overrides
		for _, pkg in existingLock.packages do
			if pkg.sourceKind == "registry" and pkg.rev then
				if previousOverrides and previousOverrides[pkg.name] then
					continue
				end
				local packageName = getRegistryPackageName(pkg.name, pkg.registry)
				local _lockedVersions = lockedRegistryVersions :: { [string]: string }
				_lockedVersions[packageName] = pkg.rev
			end
		end
	end

	return nil, lockedRegistryVersions
end

local function collectRootDependency(
	state: ResolutionState,
	rootPackageName: string,
	dependencyAlias: string,
	dependencySpec: manifest.DependencySpec,
	registryUrl: string?,
	overrides: { [string]: manifest.DependencySpec },
	isDev: boolean
)
	local effectiveSpec = overrides[dependencySpec.name] or dependencySpec

	if effectiveSpec.sourceKind == "registry" then
		local registryPackageName = registerRegistryPackage(
			state.registrySources,
			state.registryIdentitiesBySource,
			state.registryUrlByPackage,
			effectiveSpec.name,
			registryUrl
		)
		state.registryRequirements[dependencyAlias] = {
			name = registryPackageName,
			constraint = semver.parseConstraint(effectiveSpec.version),
			requiredBy = rootPackageName,
			aliasedAs = if dependencyAlias ~= effectiveSpec.name then dependencyAlias else nil,
		}

		table.insert(state.rootRegistryAliases, { alias = dependencyAlias, name = registryPackageName, dev = isDev })
		return
	end

	-- Development aliases go to their own root map; see `ResolutionState`.
	local target = if isDev then state.devDependencies else state.dependencies
	target[dependencyAlias] = getKey(effectiveSpec)
	table.insert(state.queue, effectiveSpec)
end

local function collectRootDependencies(
	rootManifest: manifest.ProjectManifest,
	overrides: { [string]: manifest.DependencySpec },
	excludeDev: boolean
): ResolutionState
	local state: ResolutionState = {
		queue = {},
		queueIndex = 1,
		dependencies = {},
		packages = {},
		registryRequirements = {},
		registrySources = {},
		registryIdentitiesBySource = {},
		rootRegistryAliases = {},
		unresolvedRegistryDependencies = {},
		openDependencies = {},
		registryUrlByPackage = {},
		devDependencies = {},
		unresolvedRegistryDevDependencies = {},
		openDevDependencies = {},
		memberKeys = getMemberKeys(rootManifest, overrides),
	}

	-- Used as `requiredBy` in solver diagnostics; a virtual root has no name.
	local rootName = rootManifest.package.name or "virtual package"

	for dependencyAlias, dependencySpec in rootManifest.package.dependencies do
		collectRootDependency(state, rootName, dependencyAlias, dependencySpec, rootManifest.registry, overrides, false)
	end

	if not excludeDev then
		for dependencyAlias, dependencySpec in rootManifest.package.devDependencies do
			collectRootDependency(
				state,
				rootName,
				dependencyAlias,
				dependencySpec,
				rootManifest.registry,
				overrides,
				true
			)
		end
	end

	return state
end

local function queueSourceOverrides(state: ResolutionState, overrides: { [string]: manifest.DependencySpec })
	local names: { string } = {}
	for name, spec in overrides do
		if spec.sourceKind ~= "registry" then
			table.insert(names, name)
		end
	end
	table.sort(names)

	for _, name in names do
		table.insert(state.queue, overrides[name])
	end
end

local function namespaceRegistryUniverse(
	universe: semver.Universe,
	registryUrl: string,
	state: ResolutionState
): semver.Universe
	local namespaced: semver.Universe = {}
	local visited: { [string]: boolean } = {}

	local function namespacePackage(source: string)
		local packageName = registerRegistryPackage(
			state.registrySources,
			state.registryIdentitiesBySource,
			state.registryUrlByPackage,
			source,
			registryUrl
		)
		if visited[packageName] then
			return
		end
		visited[packageName] = true

		local versions = universe[source]
		if versions == nil then
			return
		end

		local transformed: { semver.PackageVersion } = {}
		for _, version in versions do
			local dependencies: { [string]: semver.Requirement } = {}
			for alias, dependency in version.dependencies do
				local dependencyName = registerRegistryPackage(
					state.registrySources,
					state.registryIdentitiesBySource,
					state.registryUrlByPackage,
					dependency.name,
					registryUrl
				)
				dependencies[alias] = table.freeze({
					name = dependencyName,
					constraint = dependency.constraint,
					requiredBy = dependency.requiredBy,
					aliasedAs = dependency.aliasedAs,
				})
			end

			table.insert(
				transformed,
				table.freeze({
					name = packageName,
					version = version.version,
					versionString = version.versionString,
					dependencies = table.freeze(dependencies),
				})
			)
		end
		namespaced[packageName] = transformed

		for _, version in versions do
			for _, dependency in version.dependencies do
				namespacePackage(dependency.name)
			end
		end
	end

	for source in universe do
		namespacePackage(source)
	end

	return namespaced
end

local function resolveRegistryDependencies(
	state: ResolutionState,
	universe: semver.Universe?,
	overrides: { [string]: manifest.DependencySpec },
	lockedRegistryVersions: { [string]: string }?
)
	-- Versioned dependency resolution: solve registry dependencies and stitch them into the package graph.
	if next(state.registryRequirements) == nil then
		return
	end

	-- Build or fetch the universe.
	local effectiveUniverse: semver.Universe
	local sourceOverridedDeps: { [string]: { [string]: string } } = {}

	if universe == nil then
		local packagesByRegistryUrl: { [string]: { { name: string, source: string } } } = {}
		local seen: { [string]: boolean } = {}

		for _, req in state.registryRequirements do
			if seen[req.name] then
				continue
			end
			seen[req.name] = true

			local url = state.registryUrlByPackage[req.name]
			assert(
				url ~= nil,
				`No registry configured for package '{req.name}'. Add a 'registry' field to your loom.config.luau.`
			)

			if not packagesByRegistryUrl[url] then
				packagesByRegistryUrl[url] = {}
			end
			table.insert(packagesByRegistryUrl[url], {
				name = state.registrySources[req.name] or req.name,
				source = state.registrySources[req.name] or req.name,
			})
		end

		effectiveUniverse = {}
		for url, names in packagesByRegistryUrl do
			local partial = registry.fetchUniverse(url, names)
			local namespaced = namespaceRegistryUniverse(partial, url, state)
			for name, versions in namespaced do
				effectiveUniverse[name] = versions
			end
		end
	else
		effectiveUniverse = table.clone(universe)
		local namespacedUrls: { [string]: boolean } = {}
		for _, req in state.registryRequirements do
			local url = state.registryUrlByPackage[req.name]
			if url and not namespacedUrls[url] then
				local namespaced = namespaceRegistryUniverse(universe, url, state)
				for name, versions in namespaced do
					effectiveUniverse[name] = versions
				end
				namespacedUrls[url] = true
			end
		end
	end

	-- Build a modified universe that respects overrides.
	if next(overrides) ~= nil then
		effectiveUniverse, sourceOverridedDeps =
			buildEffectiveUniverse(effectiveUniverse, overrides, state.registrySources)
	end

	local resolution = semver.solve(effectiveUniverse, state.registryRequirements, lockedRegistryVersions)

	-- Build a lookup from package name to resolved version(s) for slot-keyed results.
	local versionsByPackageName = {}
	for _, pkgVersion in resolution do
		versionsByPackageName[pkgVersion.name] = pkgVersion
	end

	for _, pkgVersion in resolution do
		local registryPackageName = pkgVersion.name
		local key = getRegistryLockKey(state, registryPackageName, pkgVersion.versionString)
		local registryUrl = state.registryUrlByPackage[registryPackageName]
		local storeKey = if registryUrl then store.qualifyRegistryKey(key, registryUrl) else key

		local transitiveDependencies: { [string]: string } = {}
		for alias, dependency in pkgVersion.dependencies do
			local resolvedVersion = versionsByPackageName[dependency.name]
			assert(resolvedVersion ~= nil, `Solver produced an incomplete resolution: missing '{dependency.name}'`)

			transitiveDependencies[alias] = getRegistryLockKey(state, dependency.name, resolvedVersion.versionString)
		end

		-- Add back dependencies that were stripped for source overrides.
		local solverKey = `{registryPackageName}@{pkgVersion.versionString}`
		if sourceOverridedDeps[solverKey] then
			for alias, overriddenName in sourceOverridedDeps[solverKey] do
				local overrideSpec = overrides[overriddenName]
				if overrideSpec then
					transitiveDependencies[alias] = getKey(overrideSpec)
				end
			end
		end

		state.packages[key] = table.freeze({
			name = state.registrySources[registryPackageName] or registryPackageName,
			rev = pkgVersion.versionString,
			source = state.registrySources[registryPackageName] or registryPackageName,
			sourceKind = "registry" :: "registry",
			installPath = store.toStorePath(storeKey),
			dependencies = table.freeze(transitiveDependencies),
			registry = registryUrl,
		})
	end

	-- Fill in pending registry dependency keys directly into the unversioned packages' dependency tables.
	-- Done once for regular and once for development maps, which are kept apart.
	local function fillUnresolved(
		unresolved: { [string]: { [string]: string } },
		openTables: { [string]: { [string]: string } }
	)
		for pkgKey, unresolvedAliases in unresolved do
			local packageDependencies = openTables[pkgKey]
			for dependencyAlias, registryName in unresolvedAliases do
				local pkgVersion = versionsByPackageName[registryName]
				assert(pkgVersion ~= nil, `Solver did not resolve transitive registry dependency '{registryName}'`)
				packageDependencies[dependencyAlias] = getRegistryLockKey(state, registryName, pkgVersion.versionString)
			end
		end
	end
	fillUnresolved(state.unresolvedRegistryDependencies, state.openDependencies)
	fillUnresolved(state.unresolvedRegistryDevDependencies, state.openDevDependencies)

	-- Write root-level registry dependency aliases now that versions are resolved.
	for _, rootAlias in state.rootRegistryAliases do
		local req = state.registryRequirements[rootAlias.alias]
		if req == nil then
			continue
		end
		local pkgVersion = versionsByPackageName[req.name]
		assert(pkgVersion ~= nil, `Solver did not resolve root dependency '{req.name}'`)
		local target = if rootAlias.dev then state.devDependencies else state.dependencies
		target[rootAlias.alias] = getRegistryLockKey(state, req.name, pkgVersion.versionString)
	end
end

local function buildLockfile(
	state: ResolutionState,
	overrides: { [string]: manifest.DependencySpec },
	lockfilePath: string,
	registryUrl: string?
): lockfile.Lockfile
	for _, openTables in { state.openDependencies, state.openDevDependencies } do
		for _, packageDependencies in openTables do
			table.freeze(packageDependencies)
		end
	end

	table.freeze(state.packages)
	table.freeze(state.dependencies)
	table.freeze(state.devDependencies)

	local serializedOverrides = lockfile.serializeOverrides(overrides)
	local frozenOverrides: { [string]: string }? = if next(serializedOverrides)
		then table.freeze(serializedOverrides)
		else nil

	-- Version 4: version 3 plus the root and member `devDependencies` maps.
	local lock: lockfile.Lockfile = table.freeze({
		version = 4,
		packages = state.packages,
		dependencies = state.dependencies,
		devDependencies = state.devDependencies,
		overrides = frozenOverrides,
		registry = registryUrl,
	})

	fs.writeStringToFile(lockfilePath, `return {pp(lock)}\n`)

	return lock
end

local function resolve(rootDirectory: string, universe: semver.Universe?, options: ResolveOptions?): lockfile.Lockfile
	local excludeDev = if options then options.excludeDev == true else false

	local rootManifestPath = getManifestPath(rootDirectory)
	if not fs.exists(rootManifestPath) then
		error(`Manifest file not found: {rootManifestPath}`)
	end

	local lockfilePath = getLockfilePath(rootDirectory)
	local rootManifest = manifest.parseFile(rootManifestPath)

	local reusedLock, lockedRegistryVersions =
		tryReuseLockfile(rootManifest, lockfilePath, rootDirectory, excludeDev, options)
	if reusedLock then
		return reusedLock
	end

	local overrides = rootManifest.overrides
	local state = collectRootDependencies(rootManifest, overrides, excludeDev)
	queueSourceOverrides(state, overrides)
	processSourceQueue(state, rootDirectory, overrides, rootManifest.registry, excludeDev)

	resolveRegistryDependencies(state, universe, overrides, lockedRegistryVersions)

	return buildLockfile(state, rootManifest.overrides, lockfilePath, rootManifest.registry)
end

return {
	resolve = resolve,
}
