# OpenWrt fixed package inputs

The lock binds OpenWrt 24.10.3 x86_64 to its exact image digest, 13 IPK archives and seven original signed feed indexes. The compressed metadata files contain the original uncompressed Packages/Packages.sig bytes. They are data fixtures, not regenerated unsigned indexes. No private signing key is included.

Provenance: GitHub environment-locks run 34160633034 resolved/downloaded these packages in a fresh VM without installing them, verified the official signatures with the image's usign keyring, and exported the archives. The same proposed lock passed a separate network-restricted TCG full-system lifecycle on commit 250fa6d (local evidence 20260907T204836.402692Z), including opkg, procd, certificate authentication/rejection and reboot persistence. This proves QEMU x86_64 behavior, not router hardware or ImmortalWrt.

Official upstream locations and SHA-256 values are recorded per resource. Signed metadata is frozen here because upstream Packages URLs are mutable. IPKs remain external downloads; missing historical packages fail reconstruction instead of being replaced with newer versions. Each VM verifies signatures again. Weekly fresh-package runs bypass download caches for the IPKs; the separate live-opkg scenario detects upstream changes.

Changing this lock requires fresh signed resolution, review of the image/package changes and a new offline lifecycle result. Preparation alone does not approve it. Neither fixtures nor tests change installed user systems.
