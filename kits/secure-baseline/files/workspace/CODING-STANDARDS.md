# Org Coding Standards (injected by the secure-baseline kit)

This file is dropped into every workspace by the `secure-baseline` kit so the
agent and every contributor share one baseline. It is a **static** file: copied
as-is from the kit's `files/workspace/` directory, with no substitution. (For
content that depends on runtime values, the kit uses `initFiles` instead.)

## Security
- **Managed credentials** (registered with `sbx secret`) are proxy-injected and never enter this VM — you cannot read, log, or leak them.
- **Unmanaged secrets** are still your responsibility: run `detect-secrets scan` before every commit and never commit a finding. This covers secrets a human pastes in, that the agent hardcodes, or that already exist in the repo.
- Scan images you build with `docker scout cves`; don't ship fixable critical/high CVEs.
- Build only on the org's curated base images from Docker Hub (`BASE_IMAGE_NAMESPACE`, Docker Hardened Images); never pull arbitrary public images.

## Code
- Keep functions small and named for what they do.
- Add a test with every behavior change.
- Match the style of the surrounding code.
