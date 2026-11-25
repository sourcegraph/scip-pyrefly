# scip-pyrefly

A thin wrapper around `pyrefly check --report-scip` that pins pyrefly 1.5.0 and treats type errors as success.

## Usage

From the root of your project:

```shell
scip-pyrefly [--output FILE] [PROJECT_DIR] [-- PYREFLY_CHECK_ARGS...]
```

Install the project's dependencies into its `.venv` first to get cross-repository references.

### Docker

```shell
docker run --rm -v "$PWD:/work" --entrypoint /bin/sh ghcr.io/sourcegraph/scip-pyrefly \
  -c 'uv venv && uv pip install . && scip-pyrefly'
```

The image bundles pyrefly, uv, and Git. `uv venv` downloads a Python that matches `requires-python`; where GitHub is unreachable, point `UV_PYTHON_INSTALL_MIRROR` at a mirror of [python-build-standalone](https://github.com/astral-sh/python-build-standalone). There is no C compiler, so dependencies that only ship C sources fail to install. To index without dependencies, drop the `--entrypoint` and `-c` arguments.

### Nix

```shell
nix run github:sourcegraph/scip-pyrefly
```

## Updating pyrefly

Bump the version and binary hashes in [`flake.nix`](flake.nix) (`nix store prefetch-file <url>`).

## Cutting releases

The scheduled-release workflow releases the next patch version every 4 weeks (on Mondays from 2026-11-23), so the Docker image picks up the nixpkgs updates that Renovate merges weekly. It skips the release when `main` has not changed since the last one, finishes a release that failed partway, and fails when CI did not pass on `main`.

To release now, run **Actions → scheduled-release → Run workflow** on `main` for the next patch version, or **Actions → release → Run workflow** on `main` with version `M.N.P`.
