# Safe Git Workflow (Don't Overwrite GitHub)

This assumes:
- local repo folder: `ntnx-cm`
- remote repo: `nutanixed/nutanix-rx`
- local branch currently: `master`
- remote default branch: `main`

---

## 0) Go to repo and verify where you are

```bash
cd /path/to/ntnx-cm
git status
git remote -v
git branch
```

Check:
- `origin` points to `https://github.com/nutanixed/nutanix-rx.git`
- you're on `master` (or `main`, if renamed)

---

## 1) Always sync from GitHub before committing

```bash
git fetch origin
git log --oneline --decorate --graph --all -20
git pull --rebase origin main
```

Why:
- prevents accidental divergence
- reduces merge noise
- avoids pushing outdated local history

If rebase conflicts:

```bash
git status
# fix files manually
git add <fixed-files>
git rebase --continue
# or abort if needed:
# git rebase --abort
```

---

## 2) Review your changes before commit

```bash
git status
git diff
```

Optional (recommended): stage intentionally

```bash
git add <specific-file>
# repeat for each file
git status
```

Avoid `git add .` if you're unsure what changed.

---

## 3) Commit with clear message

```bash
git commit -m "Short description of what changed"
```

---

## 4) Push safely (no force)

If local branch is `master` and remote is `main`:

```bash
git push origin master:main
```

If you already switched local to `main`:

```bash
git push origin main
```

---

## 5) Verify push succeeded

```bash
git status
git log --oneline -5
```

And confirm on GitHub web UI that latest commit appears.

---

## Golden Rules (to avoid overwriting)

- Never use `git push --force` unless you fully understand the impact.
- Never use `git reset --hard` unless you intentionally want to discard local work.
- Run `git pull --rebase origin main` before every push.
- Review `git diff` and `git status` before commit.
- Commit small, focused changes.

---

## Recommended one-time branch alignment (optional)

So local and remote both use `main`:

```bash
git branch -M main
git push -u origin main
```

After this, daily flow is:

```bash
git pull --rebase origin main
git add <files>
git commit -m "message"
git push
```

---

## If you made a bad commit (safe recovery patterns)

### A) Commit is local only (not pushed yet)

```bash
# undo commit, keep file changes:
git reset --soft HEAD~1
```

### B) Commit already pushed (don't rewrite history)

```bash
# create a new commit that reverses the bad one:
git revert <commit-sha>
git push
```

---

## Optional safer team flow (feature branches)

```bash
git checkout -b feature/my-change
# edit...
git add <files>
git commit -m "Implement my change"
git push -u origin feature/my-change
```

Then open a PR to `main` on GitHub.  
This avoids direct edits to `main` and is safest long-term.
