# OpenWrt fixed package inputs

The lock binds OpenWrt 24.10.3 x86_64 to its exact image digest, 13 IPK archives and seven original signed feed indexes. The compressed metadata files contain the original uncompressed Packages/Packages.sig bytes. They are data fixtures, not regenerated unsigned indexes. No private signing key is included.

Provenance: [environment-locks run 43194261184](https://github.com/KroMiose/LazyCat-Scripts/actions/runs/43194261184) resolved and downloaded these packages in a fresh VM without installing them, verified the official signatures with the image's usign keyring, and exported the exact archives. The offline lifecycle job separately tests opkg, procd, certificate authentication and reboot persistence on QEMU x86_64. It does not cover router hardware or ImmortalWrt.

Official upstream locations and SHA-256 values are recorded per resource. Both metadata and IPK archives are frozen here because upstream can replace bytes at the same URL. Each VM verifies signatures again. Weekly fresh-package runs fetch IPKs directly from upstream and fail if their bytes differ from the lock; the separate live-opkg scenario checks current upstream behavior.

Changing this lock requires fresh signed resolution, review of the image/package changes and a new offline lifecycle result. Preparation alone does not approve it. Neither fixtures nor tests change installed user systems.
