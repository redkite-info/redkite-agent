#!/usr/bin/env bash
#
# Red Kite — the Unraid agent.
#
# Same job as the Linux agent, same payload, same hub. What is different is where it stands: this
# one runs in a container, and a container cannot see the machine it is running on unless somebody
# has deliberately shown it.
#
# ---------------------------------------------------------------------------------------------
# THE ONE MISTAKE THIS FILE EXISTS TO AVOID
#
# **A container reads its own /proc and its own /sys.** Run this without the host mounts and every
# figure is about the container: uptime a few seconds, one filesystem, no disks, no memory errors.
# It would report a machine in perfect health, for ever, and the report would be true — about the
# wrong thing.
#
# That is not a hypothetical. It has already happened once in this product, when systemd's
# ProtectSystem=strict made the Linux agent report every filesystem on a healthy server as
# read-only. Same shape of error: measuring the sandbox and calling it the machine.
#
# So: the host paths are checked before anything is gathered, and a missing one is fatal rather
# than quietly skipped. An agent that cannot see the machine must say so, not report on itself.
# ---------------------------------------------------------------------------------------------
#
# Figures, never content (§10.3). Counts, byte totals and device models. No file names, no user
# names, no share contents. Judge anything new by: if the hub database leaked, what would the
# customer mind?
#
# H3 — it sends, it does not receive instructions. One route, outbound: POST /api/v1/check-in.
# Exactly one field is read from the reply and it is validated as a bounded integer.
#
# Usage (inside the container):
#   redkite-unraid.sh              run for ever, checking in on the interval
#   redkite-unraid.sh --once       one check-in, then exit
#   redkite-unraid.sh --dry-run    print the payload, send nothing
#   redkite-unraid.sh --diagnose   a full report of what it can and cannot see, safe to paste

set -uo pipefail

readonly AGENT_VERSION="2.0.0-unraid"

# --------------------------------------------------------------------------------------------
# Where the host is, as shown to us
#
# These are the container's view of the machine. The defaults match the template; anybody running
# it by hand can move them, but they cannot be absent.
# --------------------------------------------------------------------------------------------
readonly HOST_PROC="${REDKITE_HOST_PROC:-/host/proc}"
readonly HOST_SYS="${REDKITE_HOST_SYS:-/host/sys}"
readonly HOST_ROOT="${REDKITE_HOST_ROOT:-/rootfs}"

# Unraid's own state. Optional: without it this still works, it simply knows less, and says so.
readonly EMHTTP="${REDKITE_EMHTTP:-/emhttp}"

readonly HUB_URL="${HUB_URL:-}"
readonly TOKEN="${TOKEN:-}"

readonly MIN_INTERVAL=60
readonly MAX_INTERVAL=86400
DEFAULT_INTERVAL="${INTERVAL:-300}"

readonly CURL_MAX_TIME=15
readonly CURL_CONNECT_TIMEOUT=5

readonly MAX_DISKS=40
readonly MAX_DRIVES=40

# How long between deep readings. The disks are the reason: a SMART read can wake a sleeping drive,
# and on a NAS with a dozen of them that is both unpopular and slow. Every reading below uses
# `smartctl -n standby`, which returns without spinning anything up — but the interval stays long
# anyway, because nothing it measures moves quickly.
readonly DEEP_EVERY=1800
readonly DEEP_FILE="/tmp/redkite-deep.json"

MODE="run"
for arg in "$@"; do
    case "$arg" in
        --once)     MODE="once" ;;
        --dry-run)  MODE="dry" ;;
        --diagnose) MODE="diagnose" ;;
        --version)  printf 'redkite-unraid %s\n' "$AGENT_VERSION"; exit 0 ;;
        *) printf 'redkite-unraid: unknown option %s\n' "$arg" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------------------------
# Saying things
#
# Everything goes to stdout, because that is what `docker logs` shows and what somebody will read
# from the Unraid Docker tab. **Nothing here ever prints the token**: this output is meant to be
# copied into an email.
# --------------------------------------------------------------------------------------------

say()  { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '%s  WARNING  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
bad()  { printf '%s  PROBLEM  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# Anything that might carry the token is passed through this before it is printed.
redact() {
    sed -E 's/rk_live_[A-Za-z0-9_-]+/rk_live_***REDACTED***/g; s/rk_user_[A-Za-z0-9_-]+/rk_user_***REDACTED***/g'
}

have() { command -v "$1" >/dev/null 2>&1; }

is_uint()   { [[ "${1-}" =~ ^[0-9]+$ ]] && (( ${#1} <= 18 )); }
is_number() { [[ "${1-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && (( ${#1} <= 24 )); }

json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s" | tr -d '\000-\037\177'
}

add_num() {
    is_uint "${2-}" || return 0
    printf ',"%s":%s' "$1" "$2"
}

# --------------------------------------------------------------------------------------------
# Can we see the machine at all?
#
# The check that stops this reporting on itself. Returns the number of things wrong.
# --------------------------------------------------------------------------------------------
check_mounts() {
    local problems=0

    if [[ ! -r "$HOST_PROC/uptime" ]]; then
        bad "Cannot read $HOST_PROC/uptime - the host's /proc is not mounted."
        bad "  Add:  -v /proc:$HOST_PROC:ro"
        bad "  Without it this container would report on ITSELF, not on the server."
        problems=$(( problems + 1 ))
    fi

    if [[ ! -r "$HOST_PROC/1/mounts" ]]; then
        bad "Cannot read $HOST_PROC/1/mounts - the host's real mount table is not visible."
        bad "  This needs the host's /proc mounted, and the container not in a private PID namespace."
        problems=$(( problems + 1 ))
    fi

    if [[ ! -d "$HOST_SYS/class" ]]; then
        warn "Cannot read $HOST_SYS - no board temperatures, fans or memory error counters."
        warn "  Add:  -v /sys:$HOST_SYS:ro"
    fi

    if [[ ! -d "$HOST_ROOT" ]]; then
        warn "Cannot read $HOST_ROOT - disk sizes and free space will be missing."
        warn "  Add:  -v /:$HOST_ROOT:ro"
    fi

    if [[ ! -r "$HOST_PROC/mdstat" ]]; then
        warn "Cannot read $HOST_PROC/mdstat - the Unraid array state will be missing."
        warn "  This is where parity validity and disabled disks come from."
    fi

    if [[ ! -r "$EMHTTP/disks.ini" ]]; then
        warn "Cannot read $EMHTTP/disks.ini - per-disk names and cached temperatures will be missing,"
        warn "  which means disks have to be woken to read their temperature. Add:"
        warn "  -v /var/local/emhttp:$EMHTTP:ro"
    fi

    if ! have smartctl; then
        warn "smartctl is not in this image - no disk health at all. This should not happen; report it."
    fi

    return "$problems"
}

# --------------------------------------------------------------------------------------------
# The host's figures
# --------------------------------------------------------------------------------------------

PARTS=()
add() { PARTS+=("$1"); }

gather_basics() {
    add "\"sentAt\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    add "\"agentVersion\":\"$AGENT_VERSION\""

    # The Unraid version, from the flash. Falls back to the kernel, which is always there.
    local os=""
    if [[ -r "$HOST_ROOT/etc/unraid-version" ]]; then
        os="Unraid $(tr -d '"' < "$HOST_ROOT/etc/unraid-version" | cut -d= -f2 | tr -d '\r\n')"
    fi
    [[ -z "$os" ]] && os="$(uname -sr 2>/dev/null || true)"
    [[ -n "$os" ]] && add "\"os\":\"$(json_escape "${os:0:120}")\""

    if [[ -r "$HOST_PROC/uptime" ]]; then
        local up=""
        read -r up _ < "$HOST_PROC/uptime" || true
        up="${up%%.*}"
        is_uint "$up" && add "\"uptimeSeconds\":$up"
    fi

    if [[ -r "$HOST_PROC/loadavg" ]]; then
        local l1 l5 l15
        read -r l1 l5 l15 _ < "$HOST_PROC/loadavg" || true
        if is_number "$l1" && is_number "$l5" && is_number "$l15"; then
            add "\"load\":[$l1,$l5,$l15]"
        fi
    fi

    if [[ -r "$HOST_PROC/cpuinfo" ]]; then
        local cores
        cores="$(grep -c '^processor' "$HOST_PROC/cpuinfo" 2>/dev/null || true)"
        is_uint "$cores" && (( cores > 0 && cores < 4096 )) && add "\"cpuCores\":$cores"
    fi

    if [[ -r "$HOST_PROC/meminfo" ]]; then
        local total="" avail="" swap_total="" swap_free=""
        while read -r k v _; do
            case "$k" in
                MemTotal:)     total="$v" ;;
                MemAvailable:) avail="$v" ;;
                SwapTotal:)    swap_total="$v" ;;
                SwapFree:)     swap_free="$v" ;;
            esac
        done < "$HOST_PROC/meminfo"

        if is_uint "$total" && is_uint "$avail"; then
            add "\"memory\":{\"totalBytes\":$(( total * 1024 )),\"availableBytes\":$(( avail * 1024 ))}"
        fi
        if is_uint "$swap_total" && is_uint "$swap_free"; then
            add "\"swap\":{\"totalBytes\":$(( swap_total * 1024 )),\"freeBytes\":$(( swap_free * 1024 ))}"
        fi
    fi

    # Pressure stall, where the kernel has it. The most useful number Linux has added in a decade
    # and almost nothing reads it: the proportion of the last five minutes something spent waiting.
    local pressure_parts=()
    local which
    for which in cpu io memory; do
        [[ -r "$HOST_PROC/pressure/$which" ]] || continue
        local a10="" a300="" line
        while read -r line; do
            case "$line" in
                some*)
                    [[ "$line" =~ avg10=([0-9]+\.[0-9]+) ]]  && a10="${BASH_REMATCH[1]}"
                    [[ "$line" =~ avg300=([0-9]+\.[0-9]+) ]] && a300="${BASH_REMATCH[1]}"
                    ;;
            esac
        done < "$HOST_PROC/pressure/$which"
        if is_number "$a10" && is_number "$a300"; then
            pressure_parts+=("\"$which\":{\"some10\":$a10,\"some300\":$a300}")
        fi
    done
    if (( ${#pressure_parts[@]} > 0 )); then
        add "\"pressure\":{$(IFS=,; printf '%s' "${pressure_parts[*]}")}"
    fi

    if [[ -r "$HOST_PROC/vmstat" ]]; then
        local oom=""
        while read -r k v _; do
            [[ "$k" == "oom_kill" ]] && { oom="$v"; break; }
        done < "$HOST_PROC/vmstat"
        is_uint "$oom" && add "\"oomKillsSinceBoot\":$oom"
    fi

    # Network error and drop counters, summed. They only go up, so the hub reads the difference
    # between two check-ins: a count climbing steadily is a failing cable or a NIC on its way out,
    # and the connection works the whole time. Interface names and byte counts are deliberately not
    # sent — how much data a customer moves is their business.
    if [[ -r "$HOST_PROC/net/dev" ]]; then
        local errors=0 drops=0 seen=0 line name rest
        while read -r line; do
            [[ "$line" == *:* ]] || continue
            name="${line%%:*}"; name="${name// /}"
            case "$name" in
                lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|shim*|Inter-|face) continue ;;
            esac
            rest="${line#*:}"
            local rx_e rx_d tx_e tx_d
            read -r _ _ rx_e rx_d _ _ _ _ _ _ tx_e tx_d _ <<< "$rest"
            is_uint "$rx_e" && is_uint "$rx_d" && is_uint "$tx_e" && is_uint "$tx_d" || continue
            errors=$(( errors + rx_e + tx_e )); drops=$(( drops + rx_d + tx_d )); seen=1
        done < "$HOST_PROC/net/dev"
        (( seen == 1 )) && add "\"network\":{\"errorsSinceBoot\":$errors,\"dropsSinceBoot\":$drops}"
    fi
}

# --------------------------------------------------------------------------------------------
# Filesystems
#
# **Read from the host's mount table, not the container's.** /proc/mounts inside a container is the
# container's own; /host/proc/1/mounts is init's, which is the machine's. Exactly the lesson the
# systemd sandbox taught, arriving again by a different road.
# --------------------------------------------------------------------------------------------
gather_filesystems() {
    [[ -r "$HOST_PROC/1/mounts" ]] || return 0

    # ------------------------------------------------------------------------------------
    # Which devices are writable SOMEWHERE.
    #
    # **A read-only bind mount is not a read-only filesystem**, and the difference is the whole
    # weight of the alarm. "This machine has switched a filesystem to read-only" means an I/O
    # error and silent data loss; a bind mount somebody deliberately made read-only means nothing
    # at all. The very first host this ran against had three of the second kind, which would have
    # gone out as a critical alarm on a perfectly well machine.
    #
    # So a mount is only reported read-only when *every* mount of that device is.
    # ------------------------------------------------------------------------------------
    local writable_devices=""
    local d m o
    while read -r d m _ o _; do
        case ",${o}," in
            ,ro,*|*,ro,*) ;;
            *) writable_devices="${writable_devices} ${d} " ;;
        esac
    done < "$HOST_PROC/1/mounts"

    local disks="" readonly_mounts="" seen_mounts="" count=0
    local dev mount fstype opts

    while read -r dev mount fstype opts _; do
        [[ -n "${mount:-}" && -n "${opts:-}" ]] || continue
        (( count >= MAX_DISKS )) && break

        # The same filesystem bind-mounted in three places is one disk, not three. Reporting it
        # three times fills the table with the same row and makes a NAS look like a data centre.
        case "$seen_mounts" in
            *" ${mount} "*) continue ;;
        esac
        seen_mounts="${seen_mounts} ${mount} "

        # Only filesystems somebody could lose data on. On Unraid that means the array disks, the
        # cache pools, the user shares and the flash — and none of the dozens of docker overlays.
        case "$fstype" in
            ext2|ext3|ext4|xfs|btrfs|zfs|reiserfs|vfat|shfs|fuse.shfs) : ;;
            *) continue ;;
        esac
        case "$mount" in
            /var/lib/docker/*|/var/lib/kubelet/*|/etc/*|/rootfs/var/lib/docker/*) continue ;;
        esac

        case ",${opts}," in
            ,ro,*|*,ro,*)
                # Only when this device is not writable anywhere else — see above.
                case "$writable_devices" in
                    *" ${dev} "*) ;;
                    *)
                        [[ -n "$readonly_mounts" ]] && readonly_mounts="${readonly_mounts},"
                        readonly_mounts="${readonly_mounts}\"$(json_escape "${mount:0:200}")\""
                        ;;
                esac
                ;;
        esac

        # The host path as this container can reach it. df on the container's own / would measure
        # the image, which is not a thing anybody wants to know about.
        local seen_at="$HOST_ROOT$mount"
        [[ "$mount" == "/" ]] && seen_at="$HOST_ROOT"
        [[ -d "$seen_at" ]] || continue

        local out total avail
        out="$(df -P -k "$seen_at" 2>/dev/null | tail -1)"
        [[ -n "$out" ]] || continue
        read -r _ total _ avail _ <<< "$out"
        is_uint "$total" && is_uint "$avail" && (( total > 0 )) || continue

        [[ -n "$disks" ]] && disks="${disks},"
        disks="${disks}{\"mount\":\"$(json_escape "${mount:0:200}")\",\"totalBytes\":$(( total * 1024 )),\"freeBytes\":$(( avail * 1024 ))}"
        count=$(( count + 1 ))
    done < "$HOST_PROC/1/mounts"

    [[ -n "$disks" ]] && add "\"disks\":[$disks]"

    # An empty array, not a missing key. "We looked and there were none" and "we could not look"
    # are different findings, and this is how the first one is said.
    add "\"readOnlyMounts\":[$readonly_mounts]"
}

# --------------------------------------------------------------------------------------------
# The Unraid array
#
# **Not Linux md, whatever /proc/mdstat suggests.** Unraid's driver writes a flat key=value dump
# there, which is why generic parsers — prometheus/node_exporter among them — fail on it. Read as
# key=value it is far better than ordinary mdstat: parity validity and the sync error count are
# both in it, and neither has an equivalent on a normal machine.
#
#   mdState        STARTED, STOPPED
#   mdNumInvalid   disabled disks. The red X: emulated from parity, everything still works,
#                  and there is nothing left to lose another disk to
#   mdNumDisabled  the same idea in newer releases
#   sbSyncErrs     sync errors from the last parity check. THE silent-corruption figure
#   mdResyncAction what it is doing, if anything
#   mdResync       how much there is to do, and mdResyncPos how far it has got
# --------------------------------------------------------------------------------------------
unraid_array() {
    [[ -r "$HOST_PROC/mdstat" ]] || return 0

    local state="" invalid="" disabled="" missing="" errs="" action=""
    local total="" pos="" size="" ndisks="" protected="" slots=""
    local key value

    while IFS='=' read -r key value; do
        value="${value%$'\r'}"
        case "$key" in
            mdState)         state="$value" ;;
            mdNumInvalid)    invalid="$value" ;;
            mdNumDisabled)   disabled="$value" ;;
            mdNumMissing)    missing="$value" ;;
            mdNumDisks)      ndisks="$value" ;;
            mdNumProtected)  protected="$value" ;;
            sbNumDisks)      slots="$value" ;;
            sbSyncErrs)      errs="$value" ;;
            mdResyncAction)  action="$value" ;;
            mdResync)        total="$value" ;;
            mdResyncPos)     pos="$value" ;;
            mdResyncSize)    size="$value" ;;
        esac
    done < "$HOST_PROC/mdstat"

    # **mdNumDisks is the array; sbNumDisks is the cupboard it lives in.**
    #
    # Titan reads sbNumDisks=24 and mdNumDisks=11, and the difference is not a discrepancy - the
    # array is configured for 24 slots and 11 of them hold a disk (nine data, two parity, and the
    # data slots are not even contiguous: disk1 to disk8, then disk22). Reading the superblock's
    # slot count as the disk count reported "24 of 24 healthy" on an eleven-disk array, and the
    # arithmetic underneath it was worse than the label: a failed disk would have read as 23 of 24
    # rather than 10 of 11, which is the difference between a shrug and a callout.
    #
    # So mdNumDisks first, because it describes the running array. mdNumProtected and then
    # sbNumDisks behind it, because which keys are present has varied between releases and a
    # missing count is worth approximating rather than dropping.
    [[ -z "$ndisks" ]] && ndisks="$protected"
    [[ -z "$ndisks" ]] && ndisks="$slots"

    # **mdResync is the only honest answer to "is anything running", and it has to be read before
    # it is used for anything else.**
    #
    # mdResyncAction is not cleared when a job finishes - it keeps the name of the last one, for
    # ever. Titan sat at "check P Q" for the eleven weeks since its last parity check, and the hub
    # duly reported a parity check permanently in progress at 0%: a warning that was never going to
    # clear, on a machine with nothing wrong. A monitoring system that cries wolf about routine
    # housekeeping gets its warnings ignored, which is the only thing worse than not having any.
    #
    # mdResync is the size of the job in progress and reads 0 when there is no job. So it is the
    # test, and it is taken here - before the fallback below overwrites it with the array's own
    # size, which is what destroyed the signal the first time.
    local running=0
    is_uint "$total" && (( total > 0 )) && running=1

    # Only now, for the percentage: the job's size if there is one, the array's size otherwise.
    is_uint "$total" && (( total > 0 )) || total="$size"

    # Nothing recognisable. Said out loud rather than passed over: a NAS whose array we cannot read
    # is a NAS we are not really watching, and a blank space would read like good news.
    if [[ -z "$state" ]]; then
        printf '{"name":"array","kind":"unraid","healthy":null,"state":"unreadable"}'
        return 0
    fi

    # Disabled, invalid and missing are three names for the same bad news: a slot the array is
    # covering for. Unraid uses different ones in different releases and in different situations,
    # so the largest of them is taken rather than the sum - a disk that is both invalid and
    # disabled is one disk, and counting it twice would report a fleet of failures on one drive.
    local failed=0
    local n
    for n in "$invalid" "$disabled" "$missing"; do
        is_uint "$n" && (( n > failed )) && failed="$n"
    done

    local item="{\"name\":\"array\",\"kind\":\"unraid\",\"level\":\"parity\""
    item="${item},\"state\":\"$(json_escape "${state:0:24}")\""

    if is_uint "$ndisks"; then
        item="${item},\"devicesTotal\":$ndisks,\"devicesActive\":$(( ndisks - failed ))"
    fi
    item="${item},\"devicesFailed\":$failed"

    # Straight into the field the hub already reads as silent corruption. On a normal machine that
    # is mdadm's mismatch_cnt; here it is Unraid's sync errors, and it means the same thing: blocks
    # where what is stored disagrees with what parity says should be stored.
    is_uint "$errs" && item="${item},\"mismatchCount\":$errs"

    if (( running )) && [[ -n "$action" && "$action" != "IDLE" && "$action" != "idle" ]]; then
        item="${item},\"resyncAction\":\"$(json_escape "${action:0:24}")\""
        if is_uint "$total" && is_uint "$pos" && (( total > 0 )); then
            item="${item},\"resyncPercent\":$(( pos * 100 / total ))"
        fi
    fi

    # Healthy means every disk is present and the array is running. A started array with a disabled
    # disk serves every read perfectly from parity, which is exactly why it needs saying.
    if [[ "$state" == "STARTED" ]] && (( failed == 0 )); then
        item="${item},\"healthy\":true"
    else
        item="${item},\"healthy\":false"
    fi

    printf '%s}' "$item"
}

# --------------------------------------------------------------------------------------------
# The disks
#
# **`-n standby` on every call, and it is not optional.** A SMART read wakes a sleeping drive. On a
# NAS with a dozen disks that people have deliberately spun down, waking the lot every half hour to
# ask how they are is both rude and slow. smartctl returns without touching a standby drive, and
# the temperature comes from Unraid's own cached figures instead.
# --------------------------------------------------------------------------------------------
smart_attr() {
    printf '%s' "${1-}" \
        | sed 's/{"id":/\n{"id":/g' \
        | grep -E "^\{\"id\":${2}," \
        | grep -oE '"raw":\{"value":[0-9]+' \
        | head -1 | grep -oE '[0-9]+$' || true
}

flatten() { printf '%s' "${1-}" | tr -d ' \n\r\t'; }

num_field() {
    printf '%s' "${1-}" | grep -oE "\"${2}\":-?[0-9]+" | head -1 | grep -oE -- '-?[0-9]+$' || true
}

str_field() {
    printf '%s' "${1-}" | grep -oE "\"${2}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
        | sed -E 's/^.*:[[:space:]]*"(.*)"$/\1/' || true
}

# A disk's temperature as Unraid already knows it, without waking anything.
emhttp_temp() {
    local device="$1"
    [[ -r "$EMHTTP/disks.ini" ]] || return 0

    awk -v dev="$device" '
        /^\[/ { in_section = 0 }
        $0 ~ "device=\"" dev "\"" { found = 1 }
        /^temp=/ && found { gsub(/[^0-9]/, "", $0); print $0; exit }
    ' "$EMHTTP/disks.ini" 2>/dev/null | head -1
}

gather_drives() {
    have smartctl || return 0

    local drives="" count=0
    local scan dev rest seen=""

    scan="$(timeout 30 smartctl --scan-open 2>/dev/null || true)"

    # **An NVMe drive is read through its namespace, not its controller, and scan-open cannot be
    # relied on to mention it at all.**
    #
    # smartctl --scan-open offers /dev/nvme0 - the controller, a character device whose major
    # number Linux allocates dynamically at boot. On the machine this was found on it was 247; on
    # the next it will differ, and it can move after a kernel update. Container device permissions
    # are a list of major numbers, so a rule naming the controller is right on one machine on one
    # boot. /dev/nvme0n1 is the same drive on block major 259 - fixed, documented - and returns the
    # same controller-wide SMART log. Checked against one drive through both paths: identical.
    #
    # The trap is that a device scan-open could not open is COMMENTED OUT of its output:
    #
    #     # /dev/nvme0 -d nvme # /dev/nvme0, NVMe device open failed: Operation not permitted
    #
    # so rewriting the controller path to a namespace inside the loop never ran - the line was
    # discarded as malformed long before it got there. The rewrite has to happen where the list is
    # built, not where it is read, and the namespaces are enumerated from /dev directly so that a
    # scan which refuses to mention NVMe at all still cannot hide it.
    #
    # Namespace 1 only, and only when the namespace is not already listed, so a drive is counted
    # once whichever way it was found.
    local candidates=""
    local line ns
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # Strip a leading comment marker so a refused device is still considered.
        line="${line###}"
        line="${line# }"
        candidates="${candidates}${line}"$'\n'
    done <<< "$scan"

    for ns in /dev/nvme[0-9]n1 /dev/nvme[0-9][0-9]n1; do
        [[ -e "$ns" ]] || continue
        [[ "$candidates" == *"$ns "* || "$candidates" == *"$ns"$'\n'* ]] && continue
        candidates="${candidates}${ns} -d nvme"$'\n'
    done

    while read -r dev rest; do
        (( count >= MAX_DRIVES )) && break
        [[ -n "${dev:-}" ]] || continue

        # The controller path, however it arrived, becomes the namespace.
        if [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]] && [[ -e "${dev}n1" ]]; then
            dev="${dev}n1"
        fi

        [[ "$dev" =~ ^/dev/[A-Za-z0-9/_-]{1,40}$ ]] || continue

        # A device reached two ways is still one device.
        [[ "${seen:-}" == *"|$dev|"* ]] && continue
        seen="${seen:-}|$dev|"

        local dtype=""
        [[ "${rest:-}" =~ -d[[:space:]]+([A-Za-z0-9+,_-]{1,24}) ]] && dtype="${BASH_REMATCH[1]}"

        local info
        if [[ -n "$dtype" ]]; then
            info="$(timeout 25 smartctl -H -A -i -j -n standby -d "$dtype" "$dev" 2>/dev/null || true)"
        else
            info="$(timeout 25 smartctl -H -A -i -j -n standby "$dev" 2>/dev/null || true)"
        fi
        [[ -n "$info" ]] || continue

        local flat name item
        flat="$(flatten "$info")"
        name="${dev#/dev/}"
        item="{\"name\":\"$(json_escape "${name:0:40}")\""

        local model
        model="$(str_field "$info" model_name)"
        [[ -n "$model" ]] && item="${item},\"model\":\"$(json_escape "${model:0:60}")\""

        # A sleeping disk is not a fault and must not read as one. Reported as asleep, with whatever
        # Unraid already knew about it, and left alone.
        if printf '%s' "$flat" | grep -q '"power_mode"'; then
            local mode
            mode="$(str_field "$info" power_mode)"
            if [[ "$mode" == "STANDBY" || "$mode" == "SLEEP" ]]; then
                item="${item},\"asleep\":true"
                local t
                t="$(emhttp_temp "$name")"
                is_uint "$t" && (( t > 0 && t < 120 )) && item="${item},\"temperatureC\":$t"
                [[ -n "$drives" ]] && drives="${drives},"
                drives="${drives}${item}}"
                count=$(( count + 1 ))
                continue
            fi
        fi

        if printf '%s' "$flat" | grep -q '"smart_status":'; then
            if printf '%s' "$flat" | grep -q '"smart_status":{"passed":true'; then
                item="${item},\"smartOk\":true"
            else
                item="${item},\"smartOk\":false"
            fi
        fi

        local rpm
        rpm="$(num_field "$flat" rotation_rate)"
        if is_uint "$rpm"; then
            if (( rpm == 0 )); then item="${item},\"kind\":\"ssd\""; else item="${item},\"kind\":\"hdd\""; fi
        fi
        [[ "$name" == nvme* ]] && item="${item},\"kind\":\"nvme\""

        local temp
        temp="$(printf '%s' "$flat" | grep -oE '"temperature":\{[^}]*"current":[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)"
        [[ -z "$temp" ]] && temp="$(emhttp_temp "$name")"
        item="${item}$(add_num temperatureC "$temp")"

        item="${item}$(add_num powerOnHours "$(printf '%s' "$flat" | grep -oE '"power_on_time":\{[^}]*"hours":[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)")"
        item="${item}$(add_num powerCycles  "$(num_field "$flat" power_cycle_count)")"

        # The five Backblaze attributes: the ones that actually predict a drive failing.
        item="${item}$(add_num reallocatedSectors   "$(smart_attr "$flat" 5)")"
        item="${item}$(add_num reportedUncorrect    "$(smart_attr "$flat" 187)")"
        item="${item}$(add_num commandTimeouts      "$(smart_attr "$flat" 188)")"
        item="${item}$(add_num pendingSectors       "$(smart_attr "$flat" 197)")"
        item="${item}$(add_num offlineUncorrectable "$(smart_attr "$flat" 198)")"
        item="${item}$(add_num crcErrors            "$(smart_attr "$flat" 199)")"

        local used
        used="$(num_field "$flat" percentage_used)"
        if ! is_uint "$used"; then
            local left
            left="$(smart_attr "$flat" 231)"
            is_uint "$left" && (( left <= 100 )) && used=$(( 100 - left ))
        fi
        is_uint "$used" && (( used <= 255 )) && item="${item},\"wearPercentUsed\":$used"

        item="${item}$(add_num mediaErrors         "$(num_field "$flat" media_errors)")"
        item="${item}$(add_num unsafeShutdowns     "$(num_field "$flat" unsafe_shutdowns)")"
        item="${item}$(add_num nvmeCriticalWarning "$(num_field "$flat" critical_warning)")"

        [[ -n "$drives" ]] && drives="${drives},"
        drives="${drives}${item}}"
        count=$(( count + 1 ))
    done <<< "$candidates"

    printf '%s' "$drives"
}

gather_hardware() {
    local hw=""
    hw_add() { [[ -n "$hw" ]] && hw="${hw},"; hw="${hw}$1"; }

    # Memory errors: the quietest failure a server has. A module correcting single-bit errors is
    # doing its job and telling nobody, and a module that has thrown one is far likelier than
    # average to throw an uncorrectable one.
    local ce=0 ue=0 seen=0 f v
    for f in "$HOST_SYS"/devices/system/edac/mc/mc*/ce_count \
             "$HOST_SYS"/devices/system/edac/mc/mc*/csrow*/ce_count; do
        [[ -r "$f" ]] || continue
        v="$(cat "$f" 2>/dev/null || true)"; is_uint "$v" || continue
        ce=$(( ce + v )); seen=1
    done
    for f in "$HOST_SYS"/devices/system/edac/mc/mc*/ue_count \
             "$HOST_SYS"/devices/system/edac/mc/mc*/csrow*/ue_count; do
        [[ -r "$f" ]] || continue
        v="$(cat "$f" 2>/dev/null || true)"; is_uint "$v" || continue
        ue=$(( ue + v )); seen=1
    done
    (( seen == 1 )) && { hw_add "\"eccCorrected\":$ce"; hw_add "\"eccUncorrected\":$ue"; }

    local hottest=""
    for f in "$HOST_SYS"/class/thermal/thermal_zone*/temp; do
        [[ -r "$f" ]] || continue
        v="$(cat "$f" 2>/dev/null || true)"; is_uint "$v" || continue
        local c=$(( v / 1000 ))
        (( c > 0 && c < 150 )) || continue
        [[ -z "$hottest" ]] || (( c > hottest )) && hottest="$c"
    done
    [[ -n "$hottest" ]] && hw_add "\"temperatureC\":$hottest"

    local fan_min=""
    for f in "$HOST_SYS"/class/hwmon/hwmon*/fan*_input; do
        [[ -r "$f" ]] || continue
        v="$(cat "$f" 2>/dev/null || true)"; is_uint "$v" || continue
        [[ -z "$fan_min" ]] || (( v < fan_min )) && fan_min="$v"
    done
    [[ -n "$fan_min" ]] && hw_add "\"fanRpmLowest\":$fan_min"

    hw_add "\"platform\":\"physical\""

    printf '%s' "$hw"
}

# The expensive readings, kept for half an hour. Same arrangement as the Linux probe and the
# Windows cache, for the same reason: nothing here moves quickly and disks should be left alone.
deep_reading() {
    if [[ -r "$DEEP_FILE" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$DEEP_FILE" 2>/dev/null || echo 0) ))
        if (( age >= 0 && age < DEEP_EVERY )); then
            cat "$DEEP_FILE"
            return 0
        fi
    fi

    local body drives arrays hardware
    body="{\"takenAt\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"probeVersion\":\"$AGENT_VERSION\""

    drives="$(gather_drives)"
    [[ -n "$drives" ]] && body="${body},\"drives\":[$drives]"

    arrays="$(unraid_array)"
    [[ -n "$arrays" ]] && body="${body},\"arrays\":[$arrays]"

    hardware="$(gather_hardware)"
    [[ -n "$hardware" ]] && body="${body},\"hardware\":{$hardware}"

    have smartctl || body="${body},\"smartctlMissing\":true"

    body="${body}}"
    printf '%s' "$body" > "$DEEP_FILE" 2>/dev/null || true
    printf '%s' "$body"
}

build_payload() {
    PARTS=()
    gather_basics
    gather_filesystems

    # The array state is read every time rather than cached: unlike SMART it costs nothing, and a
    # disk dropping out of the array is the one thing here nobody should hear about half an hour
    # late.
    local deep
    deep="$(deep_reading)"
    if [[ -n "$deep" && "$deep" == "{"*"}" ]]; then
        local inner="${deep#\{}"; inner="${inner%\}}"
        [[ -n "$inner" ]] && add "\"deep\":{${inner}}"
    fi

    printf '{%s}' "$(IFS=,; printf '%s' "${PARTS[*]}")"
}

# --------------------------------------------------------------------------------------------
# Sending
# --------------------------------------------------------------------------------------------
send() {
    local body="$1"
    local work response errors code

    work="$(mktemp -d)"
    printf '%s' "$body" > "$work/body.json"

    # The token goes in a config file, never on the command line: anybody on the machine can read a
    # command line out of ps.
    {
        printf 'url = "%s"\n'                         "${HUB_URL%/}/api/v1/check-in"
        printf 'request = "POST"\n'
        printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
        printf 'header = "Content-Type: application/json"\n'
        printf 'header = "Expect:"\n'
        printf 'user-agent = "redkite-unraid/%s"\n'    "$AGENT_VERSION"
        printf 'data-binary = "@%s"\n'                 "$work/body.json"
        printf 'output = "%s"\n'                       "$work/response"
        printf 'connect-timeout = %s\n'                "$CURL_CONNECT_TIMEOUT"
        printf 'max-time = %s\n'                       "$CURL_MAX_TIME"
        printf 'retry = 0\nsilent\nshow-error\n'
        printf 'write-out = "%%{http_code}"\n'
    } > "$work/curl.conf"

    code="$(curl --config "$work/curl.conf" 2>"$work/error")"
    local status=$?

    if (( status != 0 )); then
        say "Could not reach the hub ($(head -c 200 "$work/error" | tr -d '\000-\037' | redact)). This is usually the line, and the hub will notice the silence."
        rm -rf "$work"
        return 1
    fi

    case "$code" in
        200|201|202|204) ;;
        401) bad "The hub does not recognise this machine's token. Nothing will be recorded until TOKEN is corrected." ;;
        409) bad "The hub has no heartbeat set up for this machine. Somebody issued a token and did not finish adding it." ;;
        429) warn "The hub asked us to slow down. Nothing was recorded this time." ;;
        *)   bad "The hub answered $code: $(head -c 300 "$work/response" | tr -d '\000-\037' | redact)" ;;
    esac

    # ONE field is read from the reply, as digits, and nothing else (H3). No eval, no source,
    # nothing written that is later executed, nothing fetched.
    local suggested
    suggested="$(head -c 4096 "$work/response" 2>/dev/null \
        | grep -oE '"intervalSeconds"[[:space:]]*:[[:space:]]*[0-9]{1,7}' \
        | head -1 | grep -oE '[0-9]+$' || true)"

    if is_uint "$suggested" && (( suggested >= MIN_INTERVAL && suggested <= MAX_INTERVAL )); then
        if [[ "$suggested" != "$DEFAULT_INTERVAL" ]]; then
            say "The hub asked for a check-in every ${suggested}s instead of ${DEFAULT_INTERVAL}s. Noted."
            DEFAULT_INTERVAL="$suggested"
        fi
    fi

    rm -rf "$work"
    return 0
}

# --------------------------------------------------------------------------------------------
# The report somebody pastes into an email
#
# Everything it can see, everything it cannot, and why each one matters — with the token removed
# on the way out.
# --------------------------------------------------------------------------------------------
diagnose() {
    printf '\n'
    printf '%s\n' '================ RED KITE - UNRAID AGENT DIAGNOSTIC ================'
    printf 'agent            %s\n' "$AGENT_VERSION"
    printf 'taken            %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'container host   %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'hub              %s\n' "${HUB_URL:-(not set)}"
    printf 'token            %s\n' "$([[ -n "$TOKEN" ]] && printf '%s... (%s characters)' "${TOKEN:0:12}" "${#TOKEN}" || printf '(not set)')"
    printf 'interval         %s seconds\n' "$DEFAULT_INTERVAL"
    printf '\n'

    printf '%s\n' '---- what this container can see of the machine ----'
    local p
    for p in "$HOST_PROC/uptime:the host's /proc (uptime, memory, load)" \
             "$HOST_PROC/1/mounts:the host's real mount table" \
             "$HOST_PROC/mdstat:the Unraid array state" \
             "$HOST_SYS/class:the host's /sys (temperatures, memory errors)" \
             "$HOST_ROOT/etc:the host's root filesystem" \
             "$EMHTTP/disks.ini:Unraid's own disk list and cached temperatures"; do
        local path="${p%%:*}" what="${p#*:}"
        if [[ -r "$path" ]]; then
            printf '  [ok]      %-24s %s\n' "$path" "$what"
        else
            printf '  [MISSING] %-24s %s\n' "$path" "$what"
        fi
    done
    printf '\n'

    printf '%s\n' '---- tools ----'
    for t in curl smartctl df awk; do
        if have "$t"; then
            printf '  [ok]      %-10s %s\n' "$t" "$("$t" --version 2>/dev/null | head -1 | cut -c1-60)"
        else
            printf '  [MISSING] %-10s\n' "$t"
        fi
    done
    printf '\n'

    printf '%s\n' '---- the Unraid array, as read ----'
    if [[ -r "$HOST_PROC/mdstat" ]]; then
        printf '  first 25 lines of %s:\n' "$HOST_PROC/mdstat"
        head -25 "$HOST_PROC/mdstat" | sed 's/^/    /'
        printf '\n  parsed:\n    %s\n' "$(unraid_array)"
    else
        printf '  cannot read %s\n' "$HOST_PROC/mdstat"
    fi
    printf '\n'

    printf '%s\n' '---- disks ----'
    if have smartctl; then
        printf '  smartctl --scan-open:\n'
        timeout 30 smartctl --scan-open 2>&1 | sed 's/^/    /' | head -50
    else
        printf '  smartctl is not installed in this image\n'
    fi
    printf '\n'

    printf '%s\n' '---- the payload that would be sent ----'
    build_payload | redact | sed 's/^/  /'
    printf '\n\n'

    printf '%s\n' '---- problems ----'
    check_mounts || true
    printf '\n'
    printf '%s\n' '=================== END OF DIAGNOSTIC ==================='
    printf 'Safe to paste: the token above is truncated and any token in the payload is redacted.\n\n'
}

# --------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------

if [[ "$MODE" == "diagnose" ]]; then
    diagnose
    exit 0
fi

say "Red Kite Unraid agent $AGENT_VERSION starting."

if [[ -z "$HUB_URL" ]]; then
    bad "HUB_URL is not set. Set it to your hub, for example https://hub.redkite.info"
    exit 2
fi
if [[ ! "$HUB_URL" =~ ^https?://[A-Za-z0-9._~-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]]; then
    bad "HUB_URL is not a plain http or https address."
    exit 2
fi
if [[ "$MODE" != "dry" ]] && [[ ! "$TOKEN" =~ ^rk_live_[A-Za-z0-9_-]{16,191}$ ]]; then
    bad "TOKEN is missing or does not look like a Red Kite machine token."
    bad "  They begin rk_live_ and the hub shows one once, when the machine is added."
    exit 2
fi

if ! check_mounts; then
    bad "This container cannot see the machine it is running on, so it will not pretend to."
    bad "Run it again with --diagnose for the full picture, and paste that output."
    exit 3
fi

say "Host mounts look right. Reporting to ${HUB_URL%/} every ${DEFAULT_INTERVAL}s."

while true; do
    payload="$(build_payload)"

    if [[ "$MODE" == "dry" ]]; then
        printf '%s\n' "$payload" | redact
        exit 0
    fi

    send "$payload" || true

    [[ "$MODE" == "once" ]] && exit 0

    sleep "$DEFAULT_INTERVAL"
done
