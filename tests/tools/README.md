# Legacy client test dependency

This module locks Mike Farah yq v4.53.2 and its transitive dependencies. The VM driver builds yq on the host for Linux AMD64 and copies the observed binary into the read-only fixture input. It records the binary digest and Go build metadata. The Go SSH product does not depend on yq.

The legacy entrypoint scenario explicitly requires Bash, curl, OpenSSH and this yq binary before it starts. It verifies renewal behavior, not dependency-free installation. All keys, accounts and HTTP configuration payloads are fictional and remain inside disposable VMs.

Historical client/common fixtures are exact files from commit 4f5080d, before the certificate temporary-file fix. The same real renewal entrypoint demonstrates that the old implementation removes a pre-existing .tmp file, while the corrected implementation preserves it. The old RETURN trap may additionally report an unbound tmp_yaml after printing success; the proof records that original nonzero exit. Default CA path expansion is verified through real SSH signing and a new authenticated connection. Failure and rerun preserve the old certificate and key. Full old-release upgrade and native-task rollback are separate, unfinished acceptance requirements.
