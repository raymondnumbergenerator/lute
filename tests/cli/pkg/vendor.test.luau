local fs = require("@std/fs")
local path = require("@std/path")
local process = require("@std/process")
local server = require("@lute/net/server")
local store = require("@commands/pkg/loom-core/src/store")
local system = require("@std/system")
local test = require("@std/test")
local vendor = require("@commands/pkg/loom-core/src/vendor")
local zipWriter = require("@commands/pkg/loom-core/src/zipwriter")

local workingDirectory = path.join(system.tmpdir(), `lute-pkg-vendor-{process.pid()}`)
local homeDirectory = path.join(workingDirectory, "home")
local projectDirectory = path.join(workingDirectory, "project")
local lutePath = path.format(process.execPath())

local env = setmetatable({
	HOME = path.format(homeDirectory),
	USERPROFILE = path.format(homeDirectory),
}, { __index = process.env })

local function writeFile(file: path.Path, contents: string)
	fs.createDirectory(path.dirname(file), { makeParents = true })
	fs.writeStringToFile(file, contents)
end

local function writeManifest(directory: path.Path, contents: string)
	writeFile(path.join(directory, "pkg.luau"), contents)
end

local function run(...: string): process.ProcessResult
	return process.run({ lutePath, "pkg", "install", ... }, { cwd = path.format(projectDirectory), env = env })
end

local function vendored(...: string): path.Path
	return path.join(projectDirectory, ".lpm", ...)
end

-- A path package with content_root = "src" and test files excluded.
local function writeSharedPackage(directory: path.Path)
	writeManifest(
		directory,
		[[return {
	package = {
		name = "shared",
		version = "1.0.0",
		content_root = "src",
		files = { "*", "!*.test.luau" },
	},
}
]]
	)
	writeFile(path.join(directory, "src", "init.luau"), "return require('./util')\n")
	writeFile(path.join(directory, "src", "util.luau"), "return {}\n")
	writeFile(path.join(directory, "src", "init.test.luau"), "-- test\n")
	writeFile(path.join(directory, "tests", "spec.luau"), "-- outside content_root\n")
end

test.suite("LutePkgInstallVendor", function(suite)
	suite:beforeEach(function()
		if fs.exists(workingDirectory) then
			fs.removeDirectory(workingDirectory, { recursive = true })
		end
		fs.createDirectory(homeDirectory, { makeParents = true })
		fs.createDirectory(projectDirectory, { makeParents = true })
	end)

	suite:afterAll(function()
		if fs.exists(workingDirectory) then
			fs.removeDirectory(workingDirectory, { recursive = true })
		end
	end)

	suite:case("encodesLockKeysAsSingleDirectoryNames", function(assert)
		assert.eq(vendor.encodeKey("citrus@1.2.3"), "citrus@1.2.3")
		assert.eq(vendor.encodeKey("apple@feature/x"), "apple@feature%2Fx")
		assert.eq(vendor.encodeKey("a b%"), "a%20b%25")
	end)

	suite:case("vendorsPathPackageContentRootFilteredByFiles", function(assert)
		writeSharedPackage(path.join(workingDirectory, "shared"))
		writeManifest(
			projectDirectory,
			[[return { package = { name = "root", version = "0.0.0", dependencies = {
	shared = { sourceKind = "path", source = "../shared" },
} } }
]]
		)

		local result = run("--vendor")

		assert.eq(result.exitcode, 0)
		assert.strContains(result.stdout, "Vendored 1 package(s) into .lpm.")
		assert.that(fs.exists(vendored("shared", "init.luau")))
		assert.that(fs.exists(vendored("shared", "util.luau")))
		assert.that(not fs.exists(vendored("shared", "init.test.luau")))
		assert.that(not fs.exists(vendored("shared", "pkg.luau")))
		assert.that(not fs.exists(vendored("shared", "tests")))
		assert.that(not fs.exists(vendored("shared", "src")))
		assert.that(fs.exists(vendored(".pkg-vendor.luau")))
	end)

	suite:case("revendoringPrunesRemovedFilesAndPackages", function(assert)
		local sharedDirectory = path.join(workingDirectory, "shared")
		writeSharedPackage(sharedDirectory)
		writeManifest(
			path.join(workingDirectory, "other"),
			'return { package = { name = "other", version = "1.0.0" } }'
		)
		writeFile(path.join(workingDirectory, "other", "init.luau"), "return {}\n")
		writeManifest(
			projectDirectory,
			[[return { package = { name = "root", version = "0.0.0", dependencies = {
	shared = { sourceKind = "path", source = "../shared" },
	other = { sourceKind = "path", source = "../other" },
} } }
]]
		)
		assert.eq(run("--vendor").exitcode, 0)
		assert.that(fs.exists(vendored("other", "init.luau")))

		fs.remove(path.join(sharedDirectory, "src", "util.luau"))
		writeFile(path.join(sharedDirectory, "src", "nested", "deep.luau"), "return 1\n")
		writeManifest(
			projectDirectory,
			[[return { package = { name = "root", version = "0.0.0", dependencies = {
	shared = { sourceKind = "path", source = "../shared" },
} } }
]]
		)
		local result = run("--vendor")

		assert.eq(result.exitcode, 0)
		assert.that(not fs.exists(vendored("other")))
		assert.that(not fs.exists(vendored("shared", "util.luau")))
		assert.eq(fs.readFileToString(vendored("shared", "nested", "deep.luau")), "return 1\n")
	end)

	suite:case("excludeDevSkipsDevDependencies", function(assert)
		writeSharedPackage(path.join(workingDirectory, "shared"))
		writeManifest(
			projectDirectory,
			[[return { package = { name = "root", version = "0.0.0", dependencies = {}, devDependencies = {
	shared = { sourceKind = "path", source = "../shared" },
} } }
]]
		)

		local result = run("--vendor", "--exclude-dev")

		assert.eq(result.exitcode, 0)
		assert.strContains(result.stdout, "Vendored 0 package(s) into .lpm.")
		assert.that(not fs.exists(vendored("shared")))
	end)

	suite:case("installWarnsWhenVendoredPathPackageChanges", function(assert)
		local sharedDirectory = path.join(workingDirectory, "shared")
		writeSharedPackage(sharedDirectory)
		writeManifest(
			projectDirectory,
			[[return { package = { name = "root", version = "0.0.0", dependencies = {
	shared = { sourceKind = "path", source = "../shared" },
} } }
]]
		)
		assert.eq(run("--vendor").exitcode, 0)

		local clean = run()
		assert.eq(clean.exitcode, 0)
		assert.that(not string.find(clean.stdout, "out of date", 1, true))

		-- Excluded files don't count as changes.
		writeFile(path.join(sharedDirectory, "src", "init.test.luau"), "-- edited test\n")
		assert.that(not string.find(run().stdout, "out of date", 1, true))

		writeFile(path.join(sharedDirectory, "src", "util.luau"), "return { edited = true }\n")
		local stale = run()
		assert.eq(stale.exitcode, 0)
		assert.strContains(stale.stdout, "path package 'shared' changed; run pkg install --vendor")
	end)

	suite:case("vendorsGitHubTargetContentRootIntoItsOwnEntry", function(assert)
		local source = "https://github.com/owner/fruits"
		local rev = "feature/x"
		local checkout = path.join(homeDirectory, ".loom", "store", store.getGitHubCheckoutKey(source, rev))
		local apple = path.join(checkout, "modules", "apple")
		writeManifest(checkout, "return { package = {} }")
		writeManifest(apple, 'return { package = { name = "apple", version = "1.0.0", content_root = "src" } }')
		writeFile(path.join(apple, "src", "init.luau"), "return 'apple'\n")
		writeFile(path.join(apple, "tests", "apple.test.luau"), "-- outside content_root\n")
		writeFile(path.join(checkout, "modules", "banana", "init.luau"), "return 'banana'\n")

		writeManifest(
			projectDirectory,
			string.format(
				[[return { package = { name = "root", version = "0.0.0", dependencies = {
	apple = { sourceKind = "github", source = %q, rev = %q, target = "modules/apple" },
} } }
]],
				source,
				rev
			)
		)
		writeFile(
			path.join(projectDirectory, "pkg.lock.luau"),
			string.format(
				[[return {
	version = 4,
	packages = {
		[%q] = {
			name = "apple",
			rev = %q,
			source = %q,
			sourceKind = "github",
			target = "modules/apple",
			installPath = %q,
			dependencies = {},
		},
	},
	dependencies = { apple = %q },
}
]],
				`apple@{rev}`,
				rev,
				source,
				store.getGitHubInstallPath(source, rev, "modules/apple"),
				`apple@{rev}`
			)
		)

		local result = run("--vendor")

		assert.eq(result.exitcode, 0)
		assert.eq(fs.readFileToString(vendored("apple@feature%2Fx", "init.luau")), "return 'apple'\n")
		assert.that(not fs.exists(vendored("apple@feature%2Fx", "tests")))
		assert.that(not fs.exists(vendored("apple@feature%2Fx", "pkg.luau")))
		assert.that(not fs.exists(vendored("apple@feature")))
	end)

	suite:case("vendorsRegistryArchiveWhole", function(assert)
		local archive = buffer.tostring(zipWriter.write({
			{ name = "init.luau", contents = buffer.fromstring("return 'citrus'\n") },
			{
				name = "pkg.luau",
				contents = buffer.fromstring('return { package = { name = "citrus", version = "1.0.0" } }\n'),
			},
		}))
		local instance: any
		instance = server.serve({
			port = 0,
			handler = function(req: server.ReceivedRequest): server.ServerResponse
				if req.path == "/api/v1/package-index/citrus" then
					return {
						status = 200,
						body = '[{"name":"citrus","version":"1.0.0","yanked":false,"dependencies":[]}]',
					}
				elseif req.path == "/api/v1/package-content-url/citrus/1.0.0" then
					return {
						status = 200,
						body = `\{"contentUrl":"http://{instance.hostname}:{instance.port}/archive"\}`,
					}
				elseif req.path == "/archive" then
					return { status = 200, body = archive }
				end
				return { status = 404, body = "not found" }
			end,
		})

		writeManifest(
			projectDirectory,
			string.format(
				[[return {
	registry = %q,
	package = { name = "root", version = "0.0.0", dependencies = {
		citrus = { sourceKind = "registry", source = "citrus", version = "^1.0.0" },
	} },
}
]],
				`http://{instance.hostname}:{instance.port}`
			)
		)

		local result = run("--vendor")
		instance.close()

		assert.eq(result.exitcode, 0)
		assert.eq(fs.readFileToString(vendored("citrus@1.0.0", "init.luau")), "return 'citrus'\n")
		assert.that(fs.exists(vendored("citrus@1.0.0", "pkg.luau")))
	end)
end)
