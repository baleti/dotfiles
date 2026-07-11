# Function to move backward over a quoted string, handling escaped quotes
backward_over_quoted_string() {
    local quote=$1
    local pos=$CURSOR
    local char c backslash_count back_pos
    while ((pos > 0)); do
        ((pos--))
        char=${BUFFER:$pos:1}
        if [[ $char == $quote ]]; then
            # Check if the quote is escaped
            backslash_count=0
            back_pos=$pos-1
            while ((back_pos >= 0)); do
                c=${BUFFER:$back_pos:1}
                if [[ $c == '\\' ]]; then
                    ((backslash_count++))
                    ((back_pos--))
                else
                    break
                fi
            done
            if ((backslash_count % 2 == 0)); then
                # Even number of backslashes: quote is not escaped
                CURSOR=$((pos - 10))
                return
            fi
        elif [[ $char == '\\' ]]; then
            # Skip the escaped character
            ((pos--))
        fi
    done
    CURSOR=0
}

# Function to move forward over a quoted string, handling escaped quotes
forward_over_quoted_string() {
    local quote=$1
    local len=${#BUFFER}
    local pos=$CURSOR
    local char c backslash_count back_pos
    while ((pos < len)); do
        char=${BUFFER:$pos:1}
        if [[ $char == $quote ]]; then
            # Check if the quote is escaped
            backslash_count=0
            back_pos=$pos-1
            while ((back_pos >= 0)); do
                c=${BUFFER:$back_pos:1}
                if [[ $c == '\\' ]]; then
                    ((backslash_count++))
                    ((back_pos--))
                else
                    break
                fi
            done
            if ((backslash_count % 2 == 0)); then
                # Even number of backslashes: quote is not escaped
                CURSOR=$((pos + 1))
                return
            fi
        elif [[ $char == '\\' ]]; then
            # Skip the escaped character
            ((pos += 2))
            continue
        fi
        ((pos++))
    done
    CURSOR=$len
}

# Function to move backward by a "full word" or quoted string
backward-full-word() {
    local quote char
    while ((CURSOR > 0)); do
        char=${BUFFER:$CURSOR-1:1}
        if [[ $char == ' ' ]]; then
            ((CURSOR--))
        elif [[ $char == "'" || $char == '"' ]]; then
            quote=$char
            ((CURSOR--))
            backward_over_quoted_string "$quote"
            break
        else
            while ((CURSOR > 0)); do
                char=${BUFFER:$CURSOR-1:1}
                if [[ $char != ' ' && $char != "'" && $char != '"' ]]; then
                    ((CURSOR--))
                else
                    break
                fi
            done
            CURSOR=$((CURSOR - 1)) # Stop one character earlier
            break
        fi
        # Break if we're not on a space
        if ((CURSOR == 0)); then
            break
        fi
        char=${BUFFER:$CURSOR-1:1}
        if [[ $char != ' ' ]]; then
            break
        fi
    done
}

# Function to move forward by a "full word" or quoted string
forward-full-word() {
    local len=${#BUFFER} quote char
    while ((CURSOR < len)); do
        char=${BUFFER:$CURSOR:1}
        if [[ $char == ' ' ]]; then
            ((CURSOR++))
        elif [[ $char == "'" || $char == '"' ]]; then
            quote=$char
            ((CURSOR++))
            forward_over_quoted_string "$quote"
            break
        else
            while ((CURSOR < len)); do
                char=${BUFFER:$CURSOR:1}
                if [[ $char != ' ' && $char != "'" && $char != '"' ]]; then
                    ((CURSOR++))
                else
                    break
                fi
            done
            CURSOR=$((CURSOR + 1)) # Stop one character further
            break
        fi
        # Break if we're not on a space
        if ((CURSOR == len)); then
            break
        fi
        char=${BUFFER:$CURSOR:1}
        if [[ $char != ' ' ]]; then
            break
        fi
    done
}

# Function to delete the previous "full word" or quoted string
kill-backward-full-word() {
    local end_pos=$CURSOR char quote
    # Move cursor backward over spaces
    while ((CURSOR > 0)) && [[ ${BUFFER:$CURSOR-1:1} == ' ' ]]; do
        ((CURSOR--))
    done
    if ((CURSOR > 0)); then
        char=${BUFFER:$CURSOR-1:1}
        if [[ $char == "'" || $char == '"' ]]; then
            quote=$char
            ((CURSOR--))
            backward_over_quoted_string "$quote"
        else
            while ((CURSOR > 0)); do
                char=${BUFFER:$CURSOR-1:1}
                if [[ $char != ' ' && $char != "'" && $char != '"' ]]; then
                    ((CURSOR--))
                else
                    break
                fi
            done
        fi
    fi
    # Delete from new CURSOR position to end_pos
    if ((end_pos > CURSOR)); then
        BUFFER="${BUFFER:0:${CURSOR}}${BUFFER:${end_pos}}"
    fi
}

# Register the functions as ZLE widgets
zle -N backward-full-word
zle -N forward-full-word
zle -N kill-backward-full-word

bindkey '\e[1;6D' backward-full-word   # Bind Ctrl + Shift + Left Arrow
bindkey '\e[1;6C' forward-full-word    # Ctrl + Shift + Right Arrow
bindkey '^[^H' kill-backward-full-word # Alt + Backspace
