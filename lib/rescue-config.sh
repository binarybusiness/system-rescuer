# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# The user configuration that build.sh and the tests read: which SSH keys the
# stick accepts, where the API key comes from, and the machine profiles the
# agent is given. It lives outside the repository, in
# ~/.config/system-rescuer/ of the invoking user ($SUDO_USER under sudo), or in
# the directory --config or $RESCUE_CONFIG names; examples/config/ is a
# documented example.
#
#   <config>/rescue.conf       name=value lines (below); # starts a comment
#   <config>/authorized_keys   the SSH public keys allowed to log in as root
#   <config>/machines/<name>/  machine profiles (match, profile.md, copies)
#
# rescue.conf names:
#   key_file=<path>        a file holding the API key, read as the invoking user
#   key_command=<command>  a command that prints the API key, run by sh as the
#                          invoking user
#   ssh_identity=<path>    the private key whose public half is in
#                          authorized_keys; tests/qemu-boot.sh and the bench
#                          log in with it (default ~/.ssh/id_ed25519)
#   provider_url=<url>     the OpenAI-compatible model API's base URL, https only,
#                          with its /v1 (default https://api.deepseek.com/v1)
#   provider_model=<id>    the model id the API takes (default deepseek-flash)
#   provider_model_name=<text>  its display name (default DeepSeek V4.1 Flash)
#   provider_context=<n>, provider_output=<n>  token limits (256000, 32768)
#   provider_cost_input=<n>, provider_cost_output=<n>, provider_cost_cache_read=<n>
#                          US$ per million tokens (0.30, 1.20, 0.006)
#   provider_ca_file=<path>  a PEM file of the CA the proxy trusts instead of the
#                          system bundle, for a self-hosted provider
#   provider_key_prefix=<text>  the build checks the key starts with it
#                          (default sk-; an empty value turns the check off)
# A value is the rest of its line, taken literally. A path may start with ~/
# (the invoking user's home); a relative path is relative to the
# configuration directory. The file is parsed, never sourced: build.sh runs
# as root.

# rescue_user_home: the invoking user's home directory.
rescue_user_home() {
    getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6
}

# rescue_config_dir [<dir>]: the configuration directory: <dir> if given, else
# $RESCUE_CONFIG, else ~/.config/system-rescuer of the invoking user.
rescue_config_dir() {
    local dir=${1:-${RESCUE_CONFIG:-}}
    [[ -n $dir ]] || dir=$(rescue_user_home)/.config/system-rescuer
    realpath -m -- "$dir"
}

# rescue_config_get <dir> <name>: the value of <name> in <dir>/rescue.conf
# (the last one, if repeated), or nothing. Paths are not expanded here.
rescue_config_get() {
    local file=$1/rescue.conf name=$2 line value=
    [[ -r $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$name="* ]] && value=${line#"$name="}
    done < "$file"
    printf '%s' "$value"
}

# rescue_config_path <dir> <value>: a configured path made absolute.
rescue_config_path() {
    local dir=$1 value=$2
    # shellcheck disable=SC2088  # a literal ~/ in the configured value
    case $value in
        '') ;;
        '~/'*) printf '%s/%s' "$(rescue_user_home)" "${value#'~/'}" ;;
        /*) printf '%s' "$value" ;;
        *) printf '%s/%s' "$dir" "$value" ;;
    esac
}

# rescue_ssh_identity [<dir>]: the private key the tests log in with:
# $RESCUE_SSH_KEY, else the configuration's ssh_identity, else
# ~/.ssh/id_ed25519 of the invoking user.
rescue_ssh_identity() {
    local dir value
    if [[ -n ${RESCUE_SSH_KEY:-} ]]; then
        printf '%s' "$RESCUE_SSH_KEY"
        return
    fi
    dir=$(rescue_config_dir "${1:-}")
    value=$(rescue_config_get "$dir" ssh_identity)
    if [[ -n $value ]]; then
        rescue_config_path "$dir" "$value"
    else
        printf '%s/.ssh/id_ed25519' "$(rescue_user_home)"
    fi
}

# rescue_as_user <command...>: run a command as the invoking user, never as
# root: under sudo, as $SUDO_USER.
rescue_as_user() {
    if [[ -n ${SUDO_USER:-} && $EUID -eq 0 ]]; then sudo -H -u "$SUDO_USER" -- "$@"; else "$@"; fi
}

# rescue_api_key [<dir>]: print the API key from the configuration's key_file
# (read as the invoking user) or key_command (run by sh as the invoking user),
# for a caller that sends it straight into a file or a pipe. Returns 2 when
# neither is set, 1 when reading it failed.
rescue_api_key() {
    local dir path command
    dir=$(rescue_config_dir "${1:-}")
    path=$(rescue_config_path "$dir" "$(rescue_config_get "$dir" key_file)")
    command=$(rescue_config_get "$dir" key_command)
    if [[ -n $path ]]; then
        rescue_as_user cat -- "$path" || return 1
    elif [[ -n $command ]]; then
        rescue_as_user sh -c "$command" || return 1
    else
        return 2
    fi
}

# rescue_config_has <dir> <name>: succeed when <dir>/rescue.conf has a line for
# <name>, even an empty one.
rescue_config_has() {
    local file=$1/rescue.conf line
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$2="* ]] && return 0
    done < "$file"
    return 1
}

# rescue_provider_get <dir> <name>: a provider_* value of the configuration, or
# today's DeepSeek default. <name> is the key without its provider_ prefix.
rescue_provider_get() {
    local dir=$1 name=$2 value default
    case $name in
        url) default=https://api.deepseek.com/v1 ;;
        model) default=deepseek-flash ;;
        model_name) default='DeepSeek V4.1 Flash' ;;
        context) default=256000 ;;
        output) default=32768 ;;
        cost_input) default=0.30 ;;
        cost_output) default=1.20 ;;
        cost_cache_read) default=0.006 ;;
        key_prefix) default=sk- ;;
        ca_file) default='' ;;
        *) return 1 ;;
    esac
    if [[ $name == key_prefix ]] && rescue_config_has "$dir" provider_key_prefix; then
        rescue_config_get "$dir" provider_key_prefix
        return
    fi
    value=$(rescue_config_get "$dir" "provider_$name")
    printf '%s' "${value:-$default}"
}

# rescue_provider_check_key <dir> <key-file>: succeed when the key in the file
# is non-empty, has no whitespace, is at least 20 characters and starts with
# the configured prefix. Prints only the key's length, on failure.
rescue_provider_check_key() {
    local prefix len
    prefix=$(rescue_provider_get "$1" key_prefix)
    len=$(tr -d '\n' < "$2" | wc -c)
    if (( len < 20 )) || [[ -n $(tr -d '\n' < "$2" | tr -d '[:graph:]') ]] \
        || { [[ -n $prefix ]] && ! head -c "${#prefix}" "$2" | grep -qxF -- "$prefix"; }; then
        printf 'no usable API key (length %s)\n' "$len"
        return 1
    fi
}

# rescue_provider_write <config-dir> <airootfs> [<model-file>]: validate the
# configuration's provider values and write them into the image: the
# non-secret /etc/rescue/provider.conf (url, host, model, model_name, key_prefix
# (empty when none), which a key typed at boot is checked against, and, with
# a provider_ca_file, ca_file) and that CA as /etc/rescue/provider-ca.pem, and
# the provider's model, name, limit and cost into
# <airootfs>/root/.config/opencode/opencode.json. With <model-file>, also
# writes there the providerID/model the image is built with. Prints the
# reason and returns 1 on an invalid value.
rescue_provider_write() {
    local dir=$1 root=$2 model_file=${3:-}
    local url model name context output c_in c_out c_cache ca authority host path
    url=$(rescue_provider_get "$dir" url)
    model=$(rescue_provider_get "$dir" model)
    name=$(rescue_provider_get "$dir" model_name)
    context=$(rescue_provider_get "$dir" context)
    output=$(rescue_provider_get "$dir" output)
    c_in=$(rescue_provider_get "$dir" cost_input)
    c_out=$(rescue_provider_get "$dir" cost_output)
    c_cache=$(rescue_provider_get "$dir" cost_cache_read)
    local bad=''
    if [[ $url == http://* ]]; then
        echo "provider_url must be https:// (the proxy verifies TLS); got an http:// URL"; return 1
    fi
    # authority is host or host:port (a bracketed IPv6 address is not taken).
    if [[ $url =~ ^https://([A-Za-z0-9.-]+(:[0-9]{1,5})?)(/[A-Za-z0-9._~/-]*)?$ ]]; then
        authority=${BASH_REMATCH[1]}
        path=${BASH_REMATCH[3]}
        path=${path%/}
        host=${authority%%:*}
        url=https://$authority$path
    else
        echo "provider_url is not a plain https://host[:port][/path] URL"; return 1
    fi
    [[ $model =~ ^[A-Za-z0-9._:/-]+$ ]] || bad=provider_model
    [[ $name =~ ^[A-Za-z0-9._:/()+\ -]+$ ]] || bad=provider_model_name
    [[ $context =~ ^[0-9]+$ ]] || bad=provider_context
    [[ $output =~ ^[0-9]+$ ]] || bad=provider_output
    [[ $c_in =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad=provider_cost_input
    [[ $c_out =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad=provider_cost_output
    [[ $c_cache =~ ^[0-9]+(\.[0-9]+)?$ ]] || bad=provider_cost_cache_read
    [[ $(rescue_provider_get "$dir" key_prefix) =~ ^[A-Za-z0-9_.-]*$ ]] || bad=provider_key_prefix
    if [[ -n $bad ]]; then echo "$bad has an unusable value"; return 1; fi
    ca=$(rescue_config_path "$dir" "$(rescue_provider_get "$dir" ca_file)")
    if [[ -n $ca ]]; then
        rescue_as_user grep -q 'BEGIN CERTIFICATE' -- "$ca" 2>/dev/null \
            || { echo "provider_ca_file $ca is not a readable PEM certificate"; return 1; }
    fi

    install -d -m 755 "$root/etc/rescue"
    {
        printf 'url=%s\nhost=%s\nmodel=%s\nmodel_name=%s\n' "$url" "$host" "$model" "$name"
        [[ -z $ca ]] || printf 'ca_file=/etc/rescue/provider-ca.pem\n'
        printf 'key_prefix=%s\n' "$(rescue_provider_get "$dir" key_prefix)"
    } > "$root/etc/rescue/provider.conf"
    chmod 644 "$root/etc/rescue/provider.conf"
    if [[ -n $ca ]]; then
        rescue_as_user cat -- "$ca" > "$root/etc/rescue/provider-ca.pem"
        chmod 644 "$root/etc/rescue/provider-ca.pem"
    fi

    # opencode.json: the provider's model id, name, limit and cost, in place
    # of the template's lines. Each must be found exactly once.
    local json=$root/root/.config/opencode/opencode.json line out='' n_model=0 n_id=0 n_name=0 n_limit=0 n_cost=0
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            *'"model": "deepseek-direct/'*) line="  \"model\": \"deepseek-direct/$model\","; n_model=$((n_model + 1)) ;;
            *'"name": "DeepSeek V4.1 Flash"'*) line="          \"name\": \"$name\","; n_name=$((n_name + 1)) ;;
            *'"limit": {'*) line="          \"limit\": { \"context\": $context, \"output\": $output },"; n_limit=$((n_limit + 1)) ;;
            *'"cost": {'*) line="          \"cost\": { \"input\": $c_in, \"output\": $c_out, \"cache_read\": $c_cache }"; n_cost=$((n_cost + 1)) ;;
            *'": {'*) if [[ $line =~ ^(\ +)\"[^\"]+\":\ \{$ && ${BASH_REMATCH[1]} == '        ' ]]; then
                          line="        \"$model\": {"; n_id=$((n_id + 1)); fi ;;
        esac
        out+=$line$'\n'
    done < "$json"
    if (( n_model != 1 || n_id != 1 || n_name != 1 || n_limit != 1 || n_cost != 1 )); then
        echo "opencode.json does not have the lines the provider values replace"; return 1
    fi
    printf '%s' "$out" > "$json"
    [[ -z $model_file ]] || printf 'deepseek-direct/%s\n' "$model" > "$model_file"
}
