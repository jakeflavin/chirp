#!/bin/zsh
# Sets up the GitHub repository's settings: description, website, topics, Discussions, Pages, private
# vulnerability reporting, labels and branch protection. Safe to run again. Needs the GitHub CLI, signed in as
# an admin of the repository. Usage: Scripts/github-setup.sh [owner/repo]
set -euo pipefail
repo=${1:-jakeflavin/chirp}

echo "==> About"
gh repo edit $repo \
  --description "Dictate, record, check your writing, listen and summarize. On your Mac, with nothing sent anywhere." \
  --homepage "https://${repo%%/*}.github.io/${repo##*/}" \
  --enable-issues --enable-discussions --enable-wiki=false --enable-projects=false \
  --delete-branch-on-merge --allow-update-branch \
  --add-topic macos,swift,swiftui,dictation,speech-to-text,transcription,text-to-speech,grammar-checker,summarization,on-device,privacy,mlx,local-first

echo "==> Pages (deployed by the Site workflow)"
gh api -X POST repos/$repo/pages -f build_type=workflow >/dev/null 2>&1 \
  || gh api -X PUT repos/$repo/pages -f build_type=workflow >/dev/null

echo "==> Private vulnerability reporting"
gh api -X PUT repos/$repo/private-vulnerability-reporting >/dev/null

echo "==> Labels"
label() { gh label create "$1" --repo $repo --color "$2" --description "$3" --force >/dev/null; }
label bug d73a4a "Something doesn't work"
label idea a2eeef "A feature request"
label dictate F6B93B "Dictate"
label record F6B93B "Meetings, calls and voice notes"
label write F6B93B "Write checks, Fix and Rephrase"
label read F6B93B "Read aloud"
label summarize F6B93B "Summarize"
label notes F6B93B "Notes and search"
label "good first issue" 7057ff "A good place to start"

echo "==> Protect main: changes come through pull requests that pass CI"
gh api -X PUT repos/$repo/branches/main/protection --input - >/dev/null <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["build-and-test"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "Done. Discussions categories (Ideas, Q&A, Show and tell) come by default; reported content is under Settings › Moderation."
