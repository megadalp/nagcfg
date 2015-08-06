# Remove everything from the index
git rm --cached -r .

# Re-add all the deleted files to the index
# You should get lots of messages like: «warning: CRLF will be replaced by LF in <file>.»
git diff --cached --name-only -z | xargs -0 git add

# Commit
git commit -m "Fix CRLF"

# If you're doing this on a Unix/Mac OSX clone then optionally remove
# the working tree and re-check everything out with the correct line endings.
git ls-files -z | xargs -0 rm
git checkout .
