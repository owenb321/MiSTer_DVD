Merge the current feature branch into main via its PR, then clean up.

A merge request is authorisation to publish THIS branch. If the branch has never been
pushed, or has no open PR, create those first (steps 4–5) rather than stopping — but do
not take it as permission to push anything else.

**Host detection.** Read `git remote get-url origin` first and use the matching CLI for
every remote operation below:
- contains `github.com` → **`gh`**
- anything else (Forgejo) → **`tea`**, passing `--repo owenb321/MiSTer_DVD`

Steps:
1. Check the current branch. If it's already `main`, tell the user and stop.
2. Confirm the working tree is clean. If there are uncommitted changes, tell the user and
   stop — do not commit on their behalf.
3. **Sweep the user docs before publishing anything.** A merge deploys the manual, so a
   stale page goes live on merge. Invoke the `docs-sweep` skill for `main...HEAD`, or at
   minimum run:

   ```bash
   python3 tools/docs_check.py
   mkdocs build --strict
   grep -on "](#[a-z0-9-]*)" README.md
   ```

   If the branch changed anything user-visible — an OSD option, a control, an on-screen
   message, install steps, a limitation removed — and the manual does not reflect it, fix
   that first and commit it to the branch. If something needs a judgement call, report it
   and stop rather than merging stale documentation.
4. **If the branch has no upstream** (`git rev-parse --abbrev-ref @{u}` fails), push it:
   `git push -u origin <branch>`. Say that you are publishing it.
5. **Find the open PR** for this branch and match the head ref:
   - gh: `gh pr list --head <branch> --state open`
   - tea: `tea pr list --repo owenb321/MiSTer_DVD --state open`

   If none exists, create one — write the body to a temp file, never inline:
   - gh: `gh pr create --base main --head <branch> --title "<title>" --body-file /tmp/pr_body.md`
   - tea: `tea pr create --repo owenb321/MiSTer_DVD --base main --head <branch> --title "<title>" --description "$(cat /tmp/pr_body.md)"`

   Derive the title from the branch's commits. Include a short summary and a markdown
   test-plan checklist reflecting what was actually verified.
6. **Merge it:**
   - gh: `gh pr merge <number> --merge`
   - tea: `tea pr merge --repo owenb321/MiSTer_DVD <index>` — pass ONLY the index.
     `--merge` is not a valid flag there; the merge kind is `--style` and already
     defaults to a regular merge commit.

   If the merge fails immediately after another merge, re-check the PR state before
   retrying — it is usually a transient server-side recompute, not a real conflict.
7. Switch to main: `git checkout main`
8. Pull latest: `git pull`
9. Prune remote-tracking refs: `git fetch --prune`
10. Delete the local feature branch: `git branch -d <branch-name>` (use `-D` only if `-d`
   fails due to merge-detection issues with the host's merge commit).

Report the PR URL, the branch deleted, and confirm main is up to date. If steps 3 or 4
had to publish or create anything, say so explicitly — the user expects branches to stay
local until asked, so publishing is worth reporting rather than doing silently.
