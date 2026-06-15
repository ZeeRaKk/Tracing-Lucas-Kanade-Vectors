#!/usr/bin/env bash
#
# Simple Zenity application built as a small state machine.
#
#   STATE 1 (login)  : ask for a username and a password.
#                      If the credentials are wrong, go back to STATE 1.
#   STATE 2 (menu)   : let the user choose Import / Export / Quit.
#                      While an Import or Export runs, the other buttons
#                      are not reachable. The operation may last at most
#                      5 minutes; after that the window closes on its own,
#                      which we treat exactly like pressing "Quit".
#
# The script is written to be easy to follow even without programming
# experience: every step is a small, clearly named function, and the
# "main" function at the bottom simply walks through the two states.

set -u   # using a variable that was never set is treated as an error


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Longest time (in seconds) an Import or Export is allowed to take.
# 5 minutes = 300 seconds. When this limit is reached the window closes
# by itself, and we treat that the same as the user choosing "Quit".
readonly TIMEOUT_SECONDS=300

# Character used by the login form to join its fields on a single line,
# so we get back "username|password" and can split it ourselves.
readonly FIELD_SEPARATOR="|"


# ---------------------------------------------------------------------------
# STATE 1 — Login
# ---------------------------------------------------------------------------

# Shows the login form.
# On success it prints "username|password"; it returns a non-zero status
# if the user closes or cancels the form.
ask_for_credentials() {
    zenity --forms \
        --title="Login" \
        --text="Please sign in to continue" \
        --separator="$FIELD_SEPARATOR" \
        --add-entry="Username" \
        --add-password="Password"
}

# TODO: NOT IMPLEMENTED ON PURPOSE.
# This function must decide whether the given username/password are valid.
# It should return 0 when the user is authenticated, and a non-zero value
# otherwise.
#
# For now it is a placeholder that accepts everyone, so the rest of the
# application can be tried out. Replace the body with real verification
# (for example: compare against a file, call an API, query PAM, ...).
is_user_authenticated() {
    local username="$1"
    local password="$2"

    # TODO: put the real authentication check here.

    return 0   # placeholder: currently always "authenticated"
}

# Keeps showing the login form until the user is authenticated.
# Returns 0 once login succeeds, or 1 if the user cancels the form.
run_login_state() {
    while true; do
        local credentials
        credentials="$(ask_for_credentials)" || return 1   # user cancelled

        # Split "username|password" into its two parts.
        local username="${credentials%%"${FIELD_SEPARATOR}"*}"
        local password="${credentials#*"${FIELD_SEPARATOR}"}"

        if is_user_authenticated "$username" "$password"; then
            return 0   # success -> move on to the menu (STATE 2)
        fi

        # Wrong username or password: tell the user, then loop back to STATE 1.
        zenity --error \
            --title="Login failed" \
            --text="Incorrect username or password. Please try again."
    done
}


# ---------------------------------------------------------------------------
# STATE 2 — Main menu (Import / Export / Quit)
# ---------------------------------------------------------------------------

# TODO: NOT IMPLEMENTED ON PURPOSE — the real Import logic goes here.
#
# While developing, this stub only pretends to work and drives the
# progress bar: each plain number it prints is a percentage (0-100),
# and each "# text" line updates the message shown in the window.
run_import() {
    for percent in $(seq 0 10 100); do
        echo "$percent"
        echo "# Importing... ${percent}%"
        sleep 1
    done
}

# TODO: NOT IMPLEMENTED ON PURPOSE — the real Export logic goes here.
run_export() {
    for percent in $(seq 0 10 100); do
        echo "$percent"
        echo "# Exporting... ${percent}%"
        sleep 1
    done
}

# Runs one operation (Import or Export) inside a progress window.
#
# Why this matches the requirements:
#   * Only this window is on screen, so the menu's other buttons are NOT
#     reachable while the operation runs.
#   * --timeout closes the window after TIMEOUT_SECONDS (the 5-minute
#     limit). When that happens, Zenity exits with status code 5.
#
# Arguments:
#   $1 : human-readable name shown in the window ("Import" / "Export")
#   $2 : name of the function that does the actual work
#
# Returns 0 when the operation finished normally, and 1 when the
# 5-minute limit was reached (the caller should then quit the app).
perform_operation() {
    local operation_name="$1"
    local worker_function="$2"

    # The worker feeds the progress bar through the pipe.
    "$worker_function" | \
        zenity --progress \
            --title="$operation_name" \
            --text="Starting ${operation_name}..." \
            --no-cancel \
            --auto-close \
            --timeout="$TIMEOUT_SECONDS"

    # In a pipeline, PIPESTATUS[1] holds Zenity's own exit code.
    # Code 5 means the dialog closed because of the 5-minute --timeout.
    if [ "${PIPESTATUS[1]}" -eq 5 ]; then
        return 1   # time limit reached -> behave like "Quit"
    fi

    return 0   # operation finished -> go back to the menu
}

# TODO: NOT IMPLEMENTED ON PURPOSE.
# This function performs the operations that MUST happen before the
# application closes — for example: saving the current state, flushing
# buffers, deleting temporary files, closing connections, logging out, ...
#
# It is the single "Quit" routine and is reached in two situations, both
# of which must run this cleanup:
#   * the user chose "Quit" (or closed the menu window);
#   * the 5-minute limit closed an operation (treated as "Quit").
#
# If the operations are slow, you can give feedback the same way Import and
# Export do (a zenity --progress window).
quit_application() {
    # TODO: put the real pre-quit operations here.
    :   # ":" is a placeholder that does nothing; remove it once implemented.
}

# Shows the menu and reacts to the chosen action.
# Loops until the user chooses Quit (or a timeout ends the session).
# Leaving this function ALWAYS leads to quit_application (see main).
run_menu_state() {
    while true; do
        local choice
        choice="$(zenity --list \
            --title="Main menu" \
            --text="What would you like to do?" \
            --column="Action" \
            "Import" \
            "Export" \
            "Quit")"

        case "$choice" in
            "Import")
                # If the operation hit the 5-minute limit, leave the menu.
                perform_operation "Import" "run_import" || return
                ;;
            "Export")
                perform_operation "Export" "run_export" || return
                ;;
            "Quit" | "")
                # "Quit" button, Cancel, or the window was closed.
                return
                ;;
        esac
    done
}


# ---------------------------------------------------------------------------
# Main program — the state machine
# ---------------------------------------------------------------------------

main() {
    # STATE 1: keep asking until the user logs in (or cancels the form).
    if ! run_login_state; then
        exit 0   # user gave up on the login screen -> nothing more to do
    fi

    # STATE 2: the main menu.
    run_menu_state

    # Leaving the menu (Quit button OR 5-minute timeout) brings us here.
    # Run the required pre-quit operations, then end the program.
    quit_application
    exit 0
}

main "$@"
