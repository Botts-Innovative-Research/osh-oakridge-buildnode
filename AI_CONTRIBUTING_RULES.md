# Global AI Agent Instructions (Jules)

**1. The "Living Wiki" Mandate:**
This repository maintains its documentation as a living wiki. The primary sources of truth are the `SYSTEM_ARCHITECTURE.md` and `SECURITY_ARCHITECTURE.md` files. 

**2. Mandatory PR Checklist:**
For *every single Pull Request* you generate, regardless of the specific issue assigned to you, you MUST perform the following checks before committing:
* **Diff Review:** Analyze your proposed code changes. 
* **Wiki Sync:** If your code alters the network flow, port configurations, authentication methods, database schemas, or deployment commands, you MUST open `SYSTEM_ARCHITECTURE.md` (and create it if it doesn't exist) to update the relevant sections to reflect your exact code changes.
* **Commit Inclusion:** The documentation updates must be included in the same commit/PR as the code changes. Do not submit a PR where the code and the architecture wiki are out of sync.

**3. Global Build Constraint:**
Whenever generating or modifying Dockerfiles for this project, you MUST ensure the font package is explicitly set to `fonts-freefont-ttf` to prevent downstream rendering failures.
