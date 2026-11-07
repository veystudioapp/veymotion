# Recipes only call dotnet/powershell, so they work whether make runs them with cmd.exe or sh.
.PHONY: help build run test sample bundle clean

APP  = src/VeyMotion.App
CLI  = src/vmotion
DIST = dist/VeyMotion

help:
	@echo make build                  Build everything (debug)
	@echo make run [SCENE=file.json]  Run the app (demo scene, or SCENE)
	@echo make test                   Run the tests
	@echo make sample                 Write the demo scene to sample.json
	@echo make bundle                 Release build: dist/VeyMotion/VeyMotion.exe + vmotion.exe
	@echo make clean                  Remove bin, obj and dist

build:
	dotnet build

run:
	dotnet run --project $(APP) $(if $(SCENE),-- "$(SCENE)")

test:
	dotnet test

sample:
	dotnet run --project $(CLI) -- sample sample.json

# vmotion goes next to the app binary (the in-app chat looks for it there), as one self-contained file.
bundle:
	dotnet publish $(APP) -c Release -o $(DIST)
	dotnet publish $(CLI) -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o $(DIST)

# Fails with one line (instead of an error per file) when a running VeyMotion still holds its bin folder.
clean:
	@powershell -NoProfile -Command "try { Get-ChildItem -Recurse -Directory -Include bin,obj,dist | Remove-Item -Recurse -Force -ErrorAction Stop } catch { [Console]::Error.WriteLine('clean: ' + $$_.Exception.Message + ' Close VeyMotion and try again.'); exit 1 }"
