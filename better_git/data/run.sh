#!/bin/bash

# Variables
CONFIG_PATH=/data/options.json
HOME=~

GIT_REPOSITORY=$(jq --raw-output '.git_repository' $CONFIG_PATH)
GIT_BRANCH=$(jq --raw-output '.git_branch' $CONFIG_PATH)
GIT_REMOTE_USER=$(jq --raw-output '.git_remote_user' $CONFIG_PATH)
GIT_REMOTE_PASS=$(jq --raw-output '.git_remote_pass' $CONFIG_PATH)
GIT_LOCAL_EMAIL=$(jq --raw-output '.git_local_email' $CONFIG_PATH)
GIT_LOCAL_NAME=$(jq --raw-output '.git_local_name' $CONFIG_PATH)
GIT_IGNORE_INIT=$(jq --raw-output ".git_ignore_init[]" $CONFIG_PATH)

REPEAT_ACTIVE=$(jq --raw-output '.repeat_active' $CONFIG_PATH)
REPEAT_INTERVAL=$(jq --raw-output '.repeat_interval' $CONFIG_PATH)

RESTART_AUTO=$(jq --raw-output 'restart_enabled' $CONFIG_PATH)
RESTART_IGNORED_FILES=$(jq --raw-output '.restart_ignore | join(" ")' $CONFIG_PATH)

# Log Function to log messages with a timestamp and log level
function log {
    local level=$1
    local message=$2
    echo "$(date +"%Y-%m-%d %H:%M:%S") [$level] - $message"
}

function log-info {
    log "INFO" "$1"
}

function log-error {
    log "ERROR" "$1"
}

function log-fatal {
    log "FATAL" "$1"
    exit 1;
}

function commit-push {
    git add "$1"
    git commit -m "$2"
    git push origin "$GIT_BRANCH"
}

function pull {
    git pull origin "$GIT_BRANCH"
}

# Check if .git exists in the directory
function check-git {
    if [ -d "/config/.git" ]; then
        log-info "Git repository found"
        return 0
    else
        log-info "Git repository not found"
        return 1
    fi
}

function setup-user-password {
    if [ -n "$GIT_REMOTE_USER" ]; then
        # Navigate to /config directory, exiting if it fails
        cd /config || log-fatal "Failed to change directory to /config"

        log-info "Setting up credential.helper for user: ${GIT_REMOTE_USER}"

        # Configure Git to store credentials in a temporary file for this session
        git config --system credential.helper "store --file=/tmp/git-credentials"

        # Extract hostname and protocol from the repository URL
        local repo_url="$GIT_REPOSITORY"
        local proto="${repo_url%%://*}"               # Extract protocol (e.g., https)
        local stripped_url="${repo_url#*://}"         # Strip protocol from URL
        stripped_url="${stripped_url#*:*@}"           # Strip optional username:password
        stripped_url="${stripped_url#*@}"             # Strip optional user info
        local host="${stripped_url%%/*}"              # Extract hostname

        # Format credentials for Git credential command
        local cred_data="\
protocol=${proto}
host=${host}
username=${GIT_REMOTE_USER}
password=${GIT_REMOTE_PASS}
"

        # Save the credentials to the specified file
        log-info "Saving git credentials to /tmp/git-credentials"
        echo "$cred_data" | git credential approve

    else
        log-fatal "GIT_REMOTE_USER is not set; cannot set up Git credentials."
    fi
}


# Initialize git repository
function init-git {
    pushd /config || log-fatal "Failed to change directory to /config"
    git init || log-fatal "Failed to initialize git repository"
    log-info "Initialized git repository"

    # Set git user
    git config --global user.email "$GIT_LOCAL_EMAIL"
    git config --global user.name "$GIT_LOCAL_NAME"
    log-info "Set git user"

    # Copy gitignore
    cat template.gitignore >> .gitignore
    log-info "Created default .gitignore file"

    # Add additional files to gitignore
    cat "$GIT_IGNORE_INIT" >> .gitignore
    log-info "Added additional files to .gitignore"

    setup-user-password

    git remote add origin "$GIT_REPOSITORY"
    git checkout -b "$GIT_BRANCH"

    commit-push . "Initial commit"

    popd || log-fatal "Failed to change directory to previous directory"
}

function pull-and-restart {
    local CHANGED_FILES

    CHANGED_FILES=$(git fetch && git diff --name-only ..origin/"$GIT_BRANCH")
    if [ -z "${CHANGED_FILES}" ] || ! echo "${CHANGED_FILES}" | grep -q -vE "${RESTART_IGNORED_FILES}"; then
        log-info "No changes detected"
        return
    fi

    log-info "Changes detected in: $CHANGED_FILES"
    pull

    # Check if Home Assistant config is valid
    if ! ha core check; then
        log-error "Invalid Home Assistant configuration"
        return
    fi

    if [ "$RESTART_AUTO" == "true" ]; then
        log-info "Restarting Home Assistant"
        ha core restart
        log-info "Changes applied successfully"
    fi

}

# Entry
check-git || (
    log-info "Git repository not found, initializing git repository";
    init-git
)

cd /config || log-fatal "Failed to change directory to /config"

if [ "$REPEAT_ACTIVE" != "true" ]; then
    log-info "Repeat is not active, committing, pushing and pulling once"
    git stash clear
    git stash
    pull
    git stash pop || log-fatal "Failed to pop stash"
    commit-push . "Manual run changes"
    exit 0
fi

# Watch for changes in the config directory
inotifywait -m -r -e modify,create,delete --format '%w%f' --excludei '\.git/' . | while read -r file; do
    if git check-ignore -v --stdin <<< "$file" &>/dev/null; then
        continue
    fi

    log-info "Change detected in $file"
    commit-push "$file" "Change detected in $file"
done &
INOTIFY_PID=$!

# Periodically pull changes from git using watch
watch -n "$REPEAT_INTERVAL" pull-and-restart &
WATCH_PID=$!

# Catch kill signals and kill processes
trap 'kill $INOTIFY_PID $WATCH_PID' SIGINT SIGTERM EXIT
