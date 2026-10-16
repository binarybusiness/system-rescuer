# fix for screen readers
if grep -Fqa 'accessibility=' /proc/cmdline &> /dev/null; then
    setopt SINGLE_LINE_ZLE
fi

~/.automated_script.sh

# system-rescuer: start the repair agent on tty1 (in tmux session "rescue").
if [[ $(tty) == "/dev/tty1" && -z ${TMUX:-} ]]; then
    /usr/local/bin/rescue-agent-start
fi
