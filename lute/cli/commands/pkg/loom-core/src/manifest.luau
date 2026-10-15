local luau = require("@std/luau")
local path = require("@std/path")

export type SourceKind = "path" | "github" | "registry"

export type PathDependencySpec = {
	read sourceKind: "path",
	read name: string,
	-- As written in the manifest, relative to the manifest's directory. Kept for
	-- messages and for recording overrides as written.
	read source: string,
	-- `source` resolved against the declaring manifest's directory when the
	-- manifest is parsed: an absolute, normalized path. Everything after
	-- parsing uses this, so a package reached as `./modules/apple` from the
	-- root and as `../apple` from a sibling is the same directory without any
	-- caller having to normalize. The lockfile records it relative to the
	-- install root.
	read directory: string,
	-- Optional semver requirement on the target package, like Cargo's
	-- `path` + `version` dependencies. Resolution checks that the package at
	-- `source` has a satisfying version (see `checkPathVersion` in
	-- resolution.luau). A future publish step would replace the path with a
	-- registry dependency using this requirement, or `^<target version>` when
	-- it is omitted.
	read version: string?,
}

export type GitHubDependencySpec = {
	read sourceKind: "github",
	read name: string,
	read source: string,
	read rev: string,
	-- Optional directory of the package inside the repository, relative to the
	-- repository root, e.g. "modules/apple". Nil means the repository root.
	-- This is how a consumer depends on one package of a repository that groups
	-- several under a virtual package, the same way a path dependency points
	-- at a package's directory directly: virtual packages cannot be depended
	-- on, so there is no selection by name. Normalized at parse time ("./a/"
	-- becomes "a"); it may not be absolute or escape the repository.
	read target: string?,
}

export type RegistryDependencySpec = {
	read sourceKind: "registry",
	-- Unlike path/GitHub dependencies, the registry package name is always
	-- derived from source. Registry entries use the map key as their alias.
	read name: string,
	read source: string,
	read version: string,
}

export type DependencySpec = PathDependencySpec | GitHubDependencySpec | RegistryDependencySpec

export type PackageManifest = {
	-- `name` and `version` are both present or both absent. A package without
	-- them is a *virtual package*: it groups the repository's packages (its
	-- members) by listing them as path dependencies. A virtual package:
	--   * resolves through ordinary dependency resolution, so all members share
	--     one lockfile when installing from the virtual root;
	--   * is never published, and cannot satisfy a path `version` requirement;
	--   * cannot be depended on: a dependency points at a member's directory
	--     instead, with a path or a GitHub `target`.
	-- Keeping `package` mandatory, instead of a separate manifest shape for
	-- virtual roots, lets every caller keep reading `package.dependencies`.
	read name: string?,
	read version: string?,
	read dependencies: { [string]: DependencySpec },
	read devDependencies: { [string]: DependencySpec },
}

export type ProjectManifest = {
	read package: PackageManifest,
	read overrides: { [string]: DependencySpec },
	read registry: string?,
}

local function isSourceKind(s: unknown): boolean
	return s == "path" or s == "github" or s == "registry"
end

local function parseSourceKind(s: unknown): SourceKind?
	if not isSourceKind(s) then
		return nil
	end

	return s :: SourceKind
end

-- Normalizes a GitHub `target` to a relative path inside the repository, or nil
-- for the repository root. See `GitHubDependencySpec.target`.
local function parseTarget(target: unknown, name: string, sectionName: string): string?
	if target == nil then
		return nil
	end
	assert(
		typeof(target) == "string",
		`Optional 'target' field for github dependency '{name}' in {sectionName} expected to be a string`
	)
	assert(
		not path.isAbsolute(target),
		`'target' for github dependency '{name}' in {sectionName} must be relative to the repository root`
	)

	local normalized = path.normalize(target)
	assert(
		normalized.parts[1] ~= "..",
		`'target' for github dependency '{name}' in {sectionName} must stay inside the repository`
	)
	if #normalized.parts == 0 then
		return nil
	end
	return path.format(normalized)
end

-- `manifestDirectory` is the absolute directory of the manifest being parsed;
-- path dependencies are resolved against it (see `PathDependencySpec.directory`).
local function parseDependencyMap(
	raw: any,
	sectionName: string,
	manifestDirectory: string
): { [string]: DependencySpec }
	local result: { [string]: DependencySpec } = {}
	if raw == nil then
		return table.freeze(result)
	end

	for name, spec in raw do
		if typeof(spec) == "string" then
			result[name] = table.freeze({
				name = name,
				sourceKind = "registry" :: "registry",
				source = name,
				version = spec,
			})
			continue
		end

		assert(
			spec.name == nil or typeof(spec.name) == "string",
			`Optional 'name' field in dependency spec for '{name}' in {sectionName} expected to be a string`
		)
		assert(
			isSourceKind(spec.sourceKind),
			`Expected 'sourceKind' to be 'path', 'github', or 'registry' in dependency spec for '{name}' in {sectionName}, got '{spec.sourceKind}'`
		)
		assert(
			spec.source ~= nil and typeof(spec.source) == "string",
			`Expected 'source' field in dependency spec for '{name}' in {sectionName}`
		)

		if spec.sourceKind == "path" then
			-- See `PathDependencySpec.version`.
			assert(
				spec.version == nil or typeof(spec.version) == "string",
				`Optional 'version' field for path dependency '{name}' in {sectionName} expected to be a string`
			)
			result[name] = table.freeze({
				name = spec.name or name,
				sourceKind = "path" :: "path",
				source = spec.source,
				directory = path.format(path.resolve(manifestDirectory, spec.source)),
				version = spec.version,
			})
		elseif spec.sourceKind == "github" then
			assert(typeof(spec.rev) == "string", `Expected 'rev' field for github dependency '{name}' in {sectionName}`)
			result[name] = table.freeze({
				name = spec.name or name,
				sourceKind = "github" :: "github",
				source = spec.source,
				rev = spec.rev,
				target = parseTarget(spec.target, name, sectionName),
			})
		elseif spec.sourceKind == "registry" then
			assert(
				typeof(spec.version) == "string",
				`Expected 'version' field for registry dependency '{name}' in {sectionName}`
			)
			assert(
				spec.name == nil,
				`Registry dependency '{name}' in {sectionName} does not support a 'name' field; use 'source' for the registry package name`
			)
			result[name] = table.freeze({
				name = spec.source,
				sourceKind = "registry" :: "registry",
				source = spec.source,
				version = spec.version,
			})
		end
	end

	return table.freeze(result)
end

-- TODO: We should do proper error handling because this is user input.
local function parseManifest(t: unknown, manifestDirectory: string): ProjectManifest
	assert(t ~= nil and typeof(t) == "table", "Expected a table")
	local raw = t :: any
	assert(raw.package ~= nil and typeof(raw.package) == "table", "Expected 'package' field in manifest")

	local pkg = raw.package
	assert(pkg.name == nil or typeof(pkg.name) == "string", "Expected 'name' field in package manifest to be a string")
	assert(
		pkg.version == nil or typeof(pkg.version) == "string",
		"Expected 'version' field in package manifest to be a string"
	)
	-- A name without a version (or the reverse) is almost certainly a mistake,
	-- so only the all-or-nothing forms are accepted: a named package, or a
	-- virtual package. See `PackageManifest`.
	assert(
		(pkg.name == nil) == (pkg.version == nil),
		"A package declares both 'name' and 'version', or neither for a virtual package"
	)

	local dependencies = parseDependencyMap(pkg.dependencies, "dependencies", manifestDirectory)
	local devDependencies = parseDependencyMap(pkg.dev_dependencies, "dev_dependencies", manifestDirectory)

	for alias in devDependencies do
		assert(dependencies[alias] == nil, `Alias '{alias}' appears in both dependencies and dev_dependencies`)
	end

	-- Unknown top-level keys are deliberately ignored: a virtual root can export
	-- shared values (for example `common`) that members read with
	-- `require("@workspace")`, without the tool knowing about them.
	-- Path overrides are resolved against the root manifest like its own path
	-- dependencies, so `./fork` and a transitive `fork` agree.
	local overrides = parseDependencyMap(raw.overrides, "overrides", manifestDirectory)

	local registry: string? = nil
	if raw.registry ~= nil then
		assert(typeof(raw.registry) == "string", "Expected 'registry' field to be a string URL")
		registry = raw.registry
	end

	return table.freeze({
		package = table.freeze({
			name = pkg.name,
			version = pkg.version,
			dependencies = dependencies,
			devDependencies = devDependencies,
		}),
		overrides = overrides,
		registry = registry,
	})
end

local function parseFile(manifestPath: string): ProjectManifest
	local manifestTable = luau.loadModule(manifestPath)
	return parseManifest(manifestTable, path.dirname(path.format(path.resolve(manifestPath))))
end

return {
	isSourceKind = isSourceKind,
	parseSourceKind = parseSourceKind,
	parseFile = parseFile,
}
