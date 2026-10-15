local fs = require("@std/fs")
local manifest = require("@commands/pkg/loom-core/src/manifest")
local path = require("@std/path")
local system = require("@std/system")
local test = require("@std/test")

local workingDirectory = path.join(system.tmpdir(), "lute-pkg-manifest")
local manifestPath = path.join(workingDirectory, "loom.config.luau")

local function writeManifest(contents: string)
	fs.writeStringToFile(manifestPath, contents)
end

test.suite("PackageManifest", function(suite)
	suite:beforeEach(function()
		if fs.exists(workingDirectory) then
			fs.removeDirectory(workingDirectory, { recursive = true })
		end
		fs.createDirectory(workingDirectory)
	end)

	suite:case("parsesRegistryAndShorthandRegistryDependency", function(assert)
		writeManifest([[return {
	package = {
		name = "root",
		version = "0.0.0",
		dependencies = {
			citrus = "^1.0.0",
		},
	},
	registry = "https://registry.example.com",
}
]])

		local parsed = manifest.parseFile(path.format(manifestPath))
		local citrus = parsed.package.dependencies.citrus
		local registryCitrus = citrus :: manifest.RegistryDependencySpec

		assert.eq(parsed.registry, "https://registry.example.com")
		assert.eq(registryCitrus.name, "citrus")
		assert.eq(registryCitrus.sourceKind, "registry")
		assert.eq(registryCitrus.source, "citrus")
		assert.eq(registryCitrus.version, "^1.0.0")
	end)

	suite:case("usesExplicitRegistrySourceAsThePackageName", function(assert)
		writeManifest([[return {
	package = {
		name = "root",
		version = "0.0.0",
		dependencies = {
			myCitrus = {
				sourceKind = "registry",
				source = "org/citrus",
				version = "^1.0.0",
			},
		},
	},
}
]])

		local parsed = manifest.parseFile(path.format(manifestPath))
		local citrus = parsed.package.dependencies.myCitrus

		assert.eq(citrus.name, "org/citrus")
		assert.eq(citrus.source, "org/citrus")
	end)

	suite:case("rejectsExplicitNameForRegistryDependency", function(assert)
		writeManifest([[return {
	package = {
		name = "root",
		version = "0.0.0",
		dependencies = {
			myCitrus = {
				sourceKind = "registry",
				name = "citrus",
				source = "org/citrus",
				version = "^1.0.0",
			},
		},
	},
}
]])

		assert.throwsWith(
			"Registry dependency 'myCitrus' in dependencies does not support a 'name' field; use 'source' for the registry package name",
			function()
				manifest.parseFile(path.format(manifestPath))
			end
		)
	end)

	suite:case("rejectsNonStringRegistry", function(assert)
		writeManifest([[return {
	package = {
		name = "root",
		version = "0.0.0",
	},
	registry = 1,
}
]])

		assert.throwsWith("Expected 'registry' field to be a string URL", function()
			manifest.parseFile(path.format(manifestPath))
		end)
	end)
end)

-- A virtual package is a `package` without name/version; see PackageManifest.
test.suite("VirtualPackage", function(suite)
	suite:beforeEach(function()
		if fs.exists(workingDirectory) then
			fs.removeDirectory(workingDirectory, { recursive = true })
		end
		fs.createDirectory(workingDirectory)
	end)

	suite:case("parsesPackageWithoutNameOrVersion", function(assert)
		writeManifest([[return {
	package = {
		dependencies = {
			apple = { sourceKind = "path", source = "./modules/apple" },
		},
		dev_dependencies = {
			orange = "^1.0.0",
		},
	},
	common = { version = "1.0.0" },
}
]])

		local parsed = manifest.parseFile(path.format(manifestPath))

		assert.eq(parsed.package.name, nil)
		assert.eq(parsed.package.version, nil)
		assert.eq(parsed.package.dependencies.apple.source, "./modules/apple")
		assert.eq(parsed.package.devDependencies.orange.sourceKind, "registry")
	end)

	suite:case("rejectsNameWithoutVersion", function(assert)
		writeManifest([[return {
	package = { name = "root" },
}
]])

		assert.throwsWith("A package declares both 'name' and 'version', or neither for a virtual package", function()
			manifest.parseFile(path.format(manifestPath))
		end)
	end)

	suite:case("parsesPathDependencyVersion", function(assert)
		writeManifest([[return {
	package = {
		name = "banana",
		version = "1.0.0",
		dependencies = {
			apple = { sourceKind = "path", source = "../apple", version = "^1.0.0" },
		},
	},
}
]])

		local parsed = manifest.parseFile(path.format(manifestPath))
		local apple = parsed.package.dependencies.apple :: manifest.PathDependencySpec

		assert.eq(apple.version, "^1.0.0")
	end)

	-- `target` names a package directory inside a GitHub repository.
	suite:case("normalizesGitHubTarget", function(assert)
		writeManifest([[return {
	package = {
		name = "consumer",
		version = "1.0.0",
		dependencies = {
			apple = { sourceKind = "github", source = "https://github.com/owner/repo", rev = "v1", target = "./modules/apple/" },
			root = { sourceKind = "github", source = "https://github.com/owner/repo", rev = "v1", target = "." },
		},
	},
}
]])

		local parsed = manifest.parseFile(path.format(manifestPath))
		local apple = parsed.package.dependencies.apple :: manifest.GitHubDependencySpec
		local root = parsed.package.dependencies.root :: manifest.GitHubDependencySpec

		assert.eq(apple.target, "modules/apple")
		assert.eq(root.target, nil)
	end)

	suite:case("rejectsGitHubTargetOutsideRepository", function(assert)
		writeManifest([[return {
	package = {
		name = "consumer",
		version = "1.0.0",
		dependencies = {
			apple = { sourceKind = "github", source = "https://github.com/owner/repo", rev = "v1", target = "../elsewhere" },
		},
	},
}
]])

		assert.throwsWith("must stay inside the repository", function()
			manifest.parseFile(path.format(manifestPath))
		end)
	end)
end)
