# Backend image releases

Sacrum publishes container images through GitHub Actions using two update
channels:

- `master` — the continuously published development channel.
- `release` — the stable self-hosted deployment channel, published from
  semantic version tags.

Pushing to `master` or pushing a semantic version tag such as `v1.2.3` runs
`.github/workflows/build.yml`. A `master` push uses the version from
`mix.exs`; a version tag supplies the release version (`v1.2.3` becomes
`1.2.3`) and the same version is compiled into the image. The workflow builds
the existing `linux/amd64` and `linux/arm64/v8` image, then publishes:

- a channel tag (`:master` or `:release`) as a convenience pointer;
- a release version tag (`:1.2.3`) for tagged releases;
- a commit tag (`:master-<short-sha>` or `:release-<short-sha>`);
- a final multi-platform image manifest digest.

Deployments must use the digest-pinned reference from channel metadata rather
than treating a mutable channel tag as the deployed version.

## Channel metadata

The latest metadata files are published as GitHub Release assets at:

```text
https://github.com/CamonZ/sacrum/releases/download/backend-master/latest.json
https://github.com/CamonZ/sacrum/releases/download/backend-release/latest.json
```

Each file contains the channel, application version, source commit, image
name, immutable manifest digest, digest-pinned image reference, supported
platforms, and generation time. A consumer should verify that `channel` is the
requested channel and pull `image_ref` exactly as written.

The `backend-master` and `backend-release` release assets are intentionally
mutable pointers. Container tags are convenience pointers; the digest-pinned
reference in each metadata file is the deployment identity and cannot change.

## Relationship to Vertebrae client updates

This backend manifest is separate from Vertebrae's client-component update
manifests. Sacrum publishes one container image digest through
`backend-master` or `backend-release`; Vertebrae publishes signed, target-
specific GUI, CLI, daemon, and gate artifacts through `channel-master` or
`channel-release`. The shared concepts are the `master` and `release` channel
names and the tagged release version, but the manifest schemas and consumers
are intentionally different.

## Publishing a release

Create and push a semantic version tag from the commit to release:

```sh
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
```

Only tags matching `vMAJOR.MINOR.PATCH` with an optional prerelease suffix
publish the `release` channel.

This workflow only publishes the backend artifact and its metadata. Running
database migrations and replacing a self-hosted application deployment remain
responsibilities of the deployment environment.
