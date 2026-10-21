#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    fi
    printf 'Для работы скрипта нужен bash.\n' >&2
    exit 1
fi

if [[ -z "${ALT_SYNC_CRLF_FIXED:-}" ]] && LC_ALL=C grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    printf '[auto-fix] Исправление Windows-переносов строк...\n' >&2
    if ! sed -i 's/\r$//' "${BASH_SOURCE[0]}"; then
        printf '[auto-fix] Не удалось исправить переносы строк. Запустите: dos2unix %s\n' "${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    ALT_SYNC_CRLF_FIXED=1 exec bash "${BASH_SOURCE[0]}" "$@"
fi

AS_HUB_DIRS=()
for _hd in "/run/alt-sync" "${TMPDIR:-/tmp}/alt-sync-hub.$(id -u)"; do
    mkdir -p "$_hd" 2>/dev/null && chmod 777 "$_hd" 2>/dev/null \
        && [[ -w "$_hd" ]] && AS_HUB_DIRS+=("$_hd")
done
if ((${#AS_HUB_DIRS[@]} == 0)); then
    AS_HUB_DIRS=("$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-hub.XXXXXX")")
fi
AS_ARGS_FILE="${AS_HUB_DIRS[0]}/args.txt"
AS_READY_FILE="${AS_HUB_DIRS[0]}/ready"
AS_LOGBEACON="${AS_HUB_DIRS[0]}/log.path"
export AS_ARGS_FILE AS_READY_FILE AS_LOGBEACON

set -euo pipefail

if (($# > 0)); then
    _early_clean__in=("$@"); _early_clean__out=(); _early_clean__chg=0
    for _early_clean__a in "${_early_clean__in[@]}"; do
        if [[ "$_early_clean__a" =~ ^[A-Za-z0-9+/=]{8,}$ ]] \
           && [[ ! "$_early_clean__a" =~ ^(export|import|cryptopro|verify|fetch-deps)$ ]]; then
            _early_clean__d="$(printf '%s' "$_early_clean__a" | base64 -d 2>/dev/null)" || _early_clean__d=""
            if [[ -n "$_early_clean__d" && "$(printf '%s\n' "$_early_clean__d" | base64 | tr -d '\n')" == "$_early_clean__a" ]]; then
                while IFS= read -r _early_clean__l; do
                    [[ -z "$_early_clean__l" ]] && continue
                    _early_clean__out+=("$_early_clean__l")
                done <<<"$_early_clean__d"
                _early_clean__chg=1
                continue
            fi
            printf '%s WARN: Мусорный аргумент «%.24s…» (осколок env-релея) выброшен на раннем этапе.\n' \
                "$(date '+%F %T')" "$_early_clean__a" >&2
            _early_clean__chg=1
            continue
        fi
        _early_clean__out+=("$_early_clean__a")
    done
    if (( _early_clean__chg )); then
        set -- ${_early_clean__out[@]+"${_early_clean__out[@]}"}
    fi
    unset _early_clean__in _early_clean__out _early_clean__a _early_clean__d _early_clean__l _early_clean__chg
fi

SCRIPT_VERSION="1.0.37"

gui_task_trace_write() {
    [[ "${ALT_SYNC_GUI:-0}" == "1" ]] || return 0
    local _d _f _sd="${ALT_SYNC_SCRIPT_DIR:-$SCRIPT_DIR}"
    for _d in "/run/alt-sync" "/tmp" "$_sd"; do
        mkdir -p "$_d" 2>/dev/null || continue
        printf 'TASK %s\n' "$*" >"$_d/.alt_sync_task" 2>/dev/null && \
            chmod a+rw "$_d/.alt_sync_task" 2>/dev/null || true
    done
    unset _d _f _sd
    return 0
}

gui_task_trace_read() {
    local _t="" _f _sd="${ALT_SYNC_SCRIPT_DIR:-$SCRIPT_DIR}"
    if [[ -n "${ALT_SYNC_ARGS_B64:-}" ]]; then
        _t="$(printf '%s' "$ALT_SYNC_ARGS_B64" | base64 -d 2>/dev/null)" || _t=""
        if [[ -n "$_t" ]]; then printf '%s' "$_t" | tr '\n' ' '; return 0; fi
    fi
    if [[ -n "${ALT_SYNC_ARGS_FILE:-}" && -r "${ALT_SYNC_ARGS_FILE:-/nonexistent}" ]]; then
        _t="$(tr '\n' ' ' <"$ALT_SYNC_ARGS_FILE" 2>/dev/null)" || _t=""
        if [[ -n "${_t// /}" ]]; then printf '%s' "$_t"; return 0; fi
    fi
    for _f in "/run/alt-sync/.alt_sync_task" "/tmp/.alt_sync_task" "$_sd/.alt_sync_task" \
              "${TMPDIR:-/tmp}/.alt_sync_task"; do
        [[ -f "$_f" && -r "$_f" ]] || continue
        _t="$(head -1 "$_f" 2>/dev/null)" || _t=""
        _t="${_t#TASK }"
        if [[ -n "${_t// /}" ]]; then printf '%s' "$_t"; return 0; fi
    done
    for _f in "/run/alt-sync/gui.last.log" "/tmp/alt-sync-gui.last.log" \
              "$_sd/alt_sync_gui.last.log" "$_sd/logs/alt_sync_gui.last.log"; do
        [[ -f "$_f" && -r "$_f" ]] || continue
        _t="$(tail -30 "$_f" 2>/dev/null \
              | grep -a ' задача cli=' | tail -1 \
              | sed -nE 's/.* аргументы=(.*) пользователь=.*/\1/p')" || _t=""
        if [[ -n "${_t// /}" ]]; then printf '%s' "$_t"; return 0; fi
    done
    printf ''
}

if [[ "${ALT_SYNC_GUI:-0}" == "1" && "$EUID" -ne 0 && -z "${ALT_SYNC_ALLOW_SELF_ELEVATE:-}" ]]; then
    printf '%s ERROR: Бэкенд запущен без прав root в GUI-режиме (повышение должно выполнить ДО запуска).\n' "$(date '+%F %T')" >&2
    printf 'Запустите alt_sync_gui.sh v1.0.8 или выше либо вручную: sudo bash %s\n' "${BASH_SOURCE[0]}" >&2
    exit 78
fi

askpass_get_password() {
    local prompt="${1:-Введите пароль:}" ap=""

    local -a _ap_list=()
    local _c
    for _c in "${ALT_SYNC_ASKPASS_BIN:-}" "${SUDO_ASKPASS:-}" zenity yad qarma kdialog xmessage; do
        [[ -n "$_c" ]] && command -v "$_c" >/dev/null 2>&1 || continue
        local _dup=0 _d
        for _d in "${_ap_list[@]}"; do [[ "$_d" == "$_c" ]] && _dup=1 && break; done
        (( _dup )) || _ap_list+=("$_c")
    done
    local _rc=0 _out="" _errf="/dev/null" _try=0
    _errf="/tmp/alt-sync-askpass.$$.err"
    : > "$_errf" 2>/dev/null || _errf="/dev/null"
    for ap in "${_ap_list[@]}"; do
        _try=$((_try + 1))
        _out=""
        case "$ap" in
            zenity|yad)
                _out=$("$ap" --title "Alt Sync — подтверждение прав" --password \
                      --prompt "$prompt" --entry-hidden --width=430 2>"$_errf"); _rc=$? ;;
            qarma)
                _out=$("$ap" --title "Alt Sync — подтверждение прав" --password \
                      --prompt "$prompt" 2>"$_errf"); _rc=$? ;;
            kdialog)
                _out=$(kdialog --title "Alt Sync — подтверждение прав" \
                      --password "$prompt" 2>"$_errf"); _rc=$? ;;
            xmessage)
                local _pw=""
                xmessage -center -buttons "Отмена:0,Я скопировал(а) пароль в буфер:1" -timeout 90 \
                    "$prompt"$'\n'"1) Откройте любой редактор/терминал, наберите пароль и скопируйте его (Ctrl+C)."$'\n'"2) Нажмите «Я скопировал(а) пароль в буфер»." 2>/dev/null || { _rc=1; _out=""; }
                if (( _rc == 0 )); then
                    if command -v xclip >/dev/null 2>&1; then
                        _pw=$(xclip -selection clipboard -o 2>/dev/null | head -1)
                    elif command -v xsel >/dev/null 2>&1; then
                        _pw=$(xsel -b 2>/dev/null | head -1)
                    fi
                    _out="$_pw"; unset _pw
                fi ;;
            *)
                _out=$("$ap" "$prompt" 2>"$_errf"); _rc=$? ;;
        esac
        if (( _rc == 0 )) && [[ -n "$_out" ]]; then
            [[ -f "$_errf" ]] && rm -f "$_errf" 2>/dev/null
            printf '%s' "$_out"
            return 0
        fi
        if [[ "$_errf" != "/dev/null" && -s "$_errf" ]]; then
            local _emsg
            _emsg=$(head -3 "$_errf" | tr '\n' ' ')
            if declare -F log >/dev/null 2>&1; then
                log "askpass: $ap (rc=$_rc): $_emsg" 2>/dev/null || true
            fi
            printf 'askpass: %s (rc=%s): %s\n' "$ap" "$_rc" "$_emsg" >> "${ALT_SYNC_ASKPASS_ERRLOG:-/tmp/alt-sync-askpass.log}" 2>/dev/null || true
        elif (( _rc != 0 )); then
            if declare -F log >/dev/null 2>&1; then
                log "askpass: виджет $ap вернул rc=$_rc без вывода — окно могло не появиться; пробую следующий" 2>/dev/null || true
            fi
            printf 'askpass: виджет %s вернул rc=%s без вывода — пробую следующий\n' "$ap" "$_rc" >> "${ALT_SYNC_ASKPASS_ERRLOG:-/tmp/alt-sync-askpass.log}" 2>/dev/null || true
        fi
        [[ -f "$_errf" ]] && rm -f "$_errf" 2>/dev/null
    done
    return 1
}

sudo_pipe_as_root() {
    local _pw _arc _src _cmd="$*"
    if [[ "$(id -u)" == "0" ]]; then
        bash -c "$_cmd"
        return $?
    fi
    _pw=$(askpass_get_password "Для продолжения нужен пароль администратора (root):")
    _arc=$?
    if (( _arc != 0 )) || [[ -z "$_pw" ]]; then
        if [[ "$(id -u)" == "0" ]]; then
            bash -c "$_cmd"
            return $?
        fi
        unset _pw _arc
        return 10
    fi
	
    local -a _sk=(--preserve-env=ALT_SYNC_GUI --preserve-env=ALT_SYNC_ELEVATED \
                  --preserve-env=ALT_SYNC_ORIG_UID --preserve-env=ALT_SYNC_NO_ESCALATE \
                  --preserve-env=ALT_SYNC_ARGS_B64 --preserve-env=ALT_SYNC_ARGS_FILE \
                  --preserve-env=ALT_SYNC_READY_FILE \
                  --preserve-env=ALT_SYNC_SCRIPT_DIR --preserve-env=ALT_SYNC_NONINTERACTIVE \
                  --preserve-env=ALT_SYNC_TARGET_USER --preserve-env=ALT_SYNC_ALLOW_NET \
                  --preserve-env=ALT_SYNC_LOG_FILE --preserve-env=ALT_SYNC_CANCEL_FLAG --preserve-env=ALT_SYNC_BACKUP_NETWORK_KEYS \
                  --preserve-env=ALT_SYNC_BACKUP_MOZILLA --preserve-env=ALT_SYNC_CRLF_FIXED \
                  --preserve-env=ALT_SYNC_ASSUME_YES --preserve-env=ALT_SYNC_NO_AUTOINSTALL \
                  --preserve-env=ALT_SYNC_ASKPASS_BIN --preserve-env=ALT_SYNC_ORIG_USER \
                  --preserve-env=ALT_SYNC_BACKUP_DIR --preserve-env=ALT_SYNC_DEPS_CACHE_DIR \
                  --preserve-env=ALT_SYNC_APT_INTERACTIVE \
                  --preserve-env=SUDO_USER --preserve-env=SUDO_UID --preserve-env=SUDO_GID)
    if ! sudo -h 2>/dev/null | grep -q -- '--preserve-env'; then
        _sk=()
    fi
    printf '%s\n' "$_pw" | sudo -S -p '' "${_sk[@]}" bash -c "$_cmd"
    _src=$?
    unset _pw _arc
    if (( _src == 1 )); then
        if ! sudo -n true 2>/dev/null; then
            return 11
        fi
    fi
    return $_src
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="${BASH_SOURCE[0]}"
if [[ "$SELF" != /* ]]; then
    SELF="$SCRIPT_DIR/$SELF"
fi

if [[ "$SCRIPT_DIR" == *[[:space:]]* || "$SELF" == *[[:space:]]* ]]; then
    printf 'Путь к скрипту не должен содержать пробелы/табуляцию: %s\n' "$SELF" >&2
    exit 1
fi

if [[ $EUID -eq 0 ]]; then
    _early_recovered=0
    if (($# > 0)); then
        _ea_keep=()
        for _ea in "$@"; do
            case "$_ea" in
                export|export-offline|import|import-offline|cryptopro|verify|fetch-deps|\
                -y|--yes|--defaults|-h|--help|--version|-V|\
                --with-network-keys|--without-network-keys|--with-mozilla|--without-mozilla|\
                --user|--backup-dir|--user=*|--backup-dir=*)
                    _ea_keep+=("$_ea") ;;
                *[!A-Za-z0-9+/=]*)
                    _ea_keep+=("$_ea") ;;
                *)
                    if [[ "${#_ea}" -lt 8 ]]; then
                        _ea_keep+=("$_ea")
                        continue
                    fi
                    _ed="$(printf '%s' "$_ea" | base64 -d 2>/dev/null)" || _ed=""
                    if [[ -z "$_ed" ]]; then
                        _et="${_ea:0:$(( ${#_ea} - ${#_ea} % 4 ))}"
                        _ed="$(printf '%s' "$_et" | base64 -d 2>/dev/null)" || _ed=""
                    fi
                    if [[ -n "$_ed" ]] && printf '%s\n' "$_ed" | grep -aqE \
                        -e '^(export|import|cryptopro|verify|fetch-deps)' \
                        -e '^--[a-z]' ; then
                        if printf '%s' "$_ed" | LC_ALL=C grep -qa '[^[:print:][:space:]]'; then
                            printf '%s WARN: Мусорный аргумент «%s» (битый осколок env-релея) выброшен на раннем этапе.\n' "$(date '+%F %T')" "$_ea" >&2
                        else
                        while IFS= read -r _el; do
                            [[ -z "$_el" || "$_el" == "-" ]] && continue
                            _ea_keep+=("$_el"); _early_recovered=1
                        done <<<"$_ed"
                        fi
                    else
                        printf '%s WARN: Мусорный аргумент «%s» (осколок env-релея) выброшен на раннем этапе.\n' "$(date '+%F %T')" "$_ea" >&2
                    fi
                    unset _ed _et ;;
            esac
        done
        set -- ${_ea_keep[@]+"${_ea_keep[@]}"}
        unset _ea _ea_keep
    fi
    if [[ "${ALT_SYNC_GUI:-0}" != "1" ]]; then
        ALT_SYNC_GUI=1; export ALT_SYNC_GUI
    fi
    ALT_SYNC_NO_ESCALATE=1; export ALT_SYNC_NO_ESCALATE
    ALT_SYNC_ELEVATED=1; export ALT_SYNC_ELEVATED
    if [[ $# -eq 0 ]]; then
        _la=""; _lt=""; _lc=""
        for _lf in "/run/alt-sync/gui.last.log" "/tmp/alt-sync-gui.last.log" \
                   "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _lc=$(tail -20 "$_lf" 2>/dev/null \
                  | grep -a ' задача cli=' | tail -1 \
                  | sed -nE 's/.*cli=([^ ]+) .*/\1/p')
            _la=$(tail -20 "$_lf" 2>/dev/null \
                  | grep -a ' задача cli=' | tail -1 \
                  | sed -nE 's/.*cli=[^ ]+ [^ ]*=(.*) пользователь=.*/\1/p')
            [[ -n "$_la" ]] && break
        done
        if [[ -n "$_la" ]]; then
            set -- $_la
            case "${1:-}" in
                export|export-offline|import|import-offline|cryptopro|verify|fetch-deps) : ;;
                *)  case "$_lc" in
                        export|export-offline|import|import-offline|cryptopro|verify|fetch-deps)
                            set -- "$_lc" "$@" ;;
                    esac ;;
            esac
            printf '%s INFO: Действие восстановлено из следа GUI (точная CLI-строка): %s\n' "$(date '+%F %T')" "$*" >&2
        else
        _tt="$(gui_task_trace_read)" || _tt=""
        if [[ -n "${_tt// /}" ]]; then
            set -- $_tt
            printf '%s INFO: Действие восстановлено из следа задачи: %s\n' "$(date '+%F %T')" "$*" >&2
        else
        for _lf in "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _la=$(tail -5 "$_lf" 2>/dev/null \
                  | grep -a 'форма rc=0' | tail -1 \
                  | sed -nE 's/.*вывод="([^"|]*)\|.*/\1/p')
            [[ -n "$_la" ]] && break
        done
        for _lf in "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _lt=$(tail -5 "$_lf" 2>/dev/null \
                  | grep -a 'форма rc=0' | tail -1 \
                  | sed -nE 's/.*вывод="[^|]*\|([^|]*)\|.*/\1/p')
            [[ -n "$_lt" ]] && break
        done
        case "$_la" in
            *локальн*|*без\ сети*) set -- export-offline --yes ;;
            *Экспорт\ эталона*)    set -- export --yes ;;
            *Импорт*клон*|*Импорт*)
                if [[ "$_la" == *офлайн* ]]; then set -- import-offline --yes
                else set -- import --defaults; fi ;;
            *CryptoPro*|*cryptopro*) set -- cryptopro --yes ;;
            *Проверка*бэкапа*|*verify*) set -- verify --yes ;;
            *Зависимост*|*fetch*)  set -- fetch-deps --yes ;;
            *)
                case "$_lt" in
                    WIFI)   set -- export-offline --yes ;;
                    IMPORT*) [[ "$_la" == *офлайн* ]] && set -- import-offline --yes || set -- import --defaults ;;
                    *)      set -- export --yes ;;
                esac
                ;;
        esac
        [[ $# -gt 0 ]] && printf '%s INFO: Действие восстановлено из следа последнего запуска GUI (%s): %s\n' "$(date '+%F %T')" "$_la" "$*" >&2
        fi
        fi
        unset _la _lt _lf _lf2 _tt
    fi
    printf 'Работаем от root (повышение выполнено GUI-оболочкой) — повторный запрос пароля не требуется.\n' >&2
elif [[ $EUID -ne 0 ]]; then
    _AS_NONINTERACTIVE="${ALT_SYNC_NONINTERACTIVE:-0}"
    _AS_ASSUME_YES="${ALT_SYNC_ASSUME_YES:-0}"
    _AS_TARGET_USER="${ALT_SYNC_TARGET_USER:-}"
    _AS_NET_KEYS="${ALT_SYNC_BACKUP_NETWORK_KEYS:-0}"
    _AS_MOZILLA="${ALT_SYNC_BACKUP_MOZILLA:-0}"
    _AS_GUI="${ALT_SYNC_GUI:-0}"
    _AS_ALLOW_NET="${ALT_SYNC_ALLOW_NET:-0}"
    _AS_NO_AUTOINSTALL="${ALT_SYNC_NO_AUTOINSTALL:-0}"
    _AS_BACKUP_DIR="${ALT_SYNC_BACKUP_DIR:-}"

    if [[ "${ALT_SYNC_ELEVATED:-}" == "1" ]] && [[ "$(id -u)" != "0" ]]; then
        printf 'Предупреждение: ALT_SYNC_ELEVATED=1 без root-прав — работаю как обычный пользователь (без повторного запроса пароля).\n' >&2
        _et="$(gui_task_trace_read)" || _et=""
        if [[ -n "${_et// /}" ]]; then
            set -- $_et
            printf '%s INFO: Действие восстановлено из следа задачи (не-root): %s\n' "$(date '+%F %T')" "$*" >&2
        fi
        unset _et
    elif [[ "${ALT_SYNC_NO_ESCALATE:-}" == "1" && "${ALT_SYNC_GUI:-0}" == "1" ]] && [[ "$(id -u)" != "0" ]]; then
        # Эскалация уже была выполнена GUI-оболочкой ровно один раз. Повторный
        # запрос пароля здесь запрещён: если прав не хватает — завершаемся с
        # явной ошибкой, а не открываем второе окно ввода пароля и не уходим в
        # невидимое интерактивное меню.
        printf 'ERROR: Задача требует прав root, но эскалация отключена (ALT_SYNC_NO_ESCALATE=1) и текущий uid=%s.\n' "$(id -u)" >&2
        printf 'Повторный запрос пароля не выполняется. Запустите вручную: sudo bash %s <действие> [флаги]\n' "${BASH_SOURCE[0]}" >&2
        exit 78
    elif [[ "${ALT_SYNC_ELEVATED:-}" == "1" && -z "${SUDO_USER:-}" ]]; then
        if [[ "$(id -u)" == "0" ]]; then
            printf 'Предупреждение: SUDO_USER пуст при ALT_SYNC_ELEVATED=1, но эффективный uid=root (0) — продолжаем работу.\n' >&2
        elif [[ -n "${ALT_SYNC_NO_ESCALATE:-}" ]]; then
            printf 'Эскалация прав отключена (ALT_SYNC_NO_ESCALATE) — работаю с текущими правами без повторного ввода пароля.\n' >&2
        else
            printf 'Повышение прав не удалось (sudo/pkexec не вернули root-окружение).\nЗапустите вручную от имени root: sudo bash %s\n' "$SELF" >&2
            exit 1
        fi
    fi
    _as_env=()
    _as_env+=(DEBIAN_FRONTEND=noninteractive ALT_SYNC_ELEVATED=1 \
             "ALT_SYNC_ORIG_UID=$(id -u)")
    [[ -n "${ALT_SYNC_NO_ESCALATE:-}" ]] && _as_env+=("ALT_SYNC_NO_ESCALATE=$ALT_SYNC_NO_ESCALATE")
    [[ -n "${ALT_SYNC_CRLF_FIXED:-}" ]] && _as_env+=("ALT_SYNC_CRLF_FIXED=$ALT_SYNC_CRLF_FIXED")
    _as_env+=("ALT_SYNC_SCRIPT_DIR=$SCRIPT_DIR"
             "ALT_SYNC_NONINTERACTIVE=$_AS_NONINTERACTIVE"
             "ALT_SYNC_ASSUME_YES=$_AS_ASSUME_YES")
    [[ -n "$_AS_TARGET_USER"  ]] && _as_env+=("ALT_SYNC_TARGET_USER=$_AS_TARGET_USER")
    _as_env+=("ALT_SYNC_BACKUP_NETWORK_KEYS=$_AS_NET_KEYS"
             "ALT_SYNC_BACKUP_MOZILLA=$_AS_MOZILLA"
             "ALT_SYNC_GUI=$_AS_GUI"
             "ALT_SYNC_ALLOW_NET=$_AS_ALLOW_NET"
             "ALT_SYNC_NO_AUTOINSTALL=$_AS_NO_AUTOINSTALL")
    [[ -n "$_AS_BACKUP_DIR" ]] && _as_env+=("ALT_SYNC_BACKUP_DIR=$_AS_BACKUP_DIR")
    [[ -n "${ALT_SYNC_ARGS_B64:-}" ]] && _as_env+=("ALT_SYNC_ARGS_B64=$ALT_SYNC_ARGS_B64")
    [[ -n "${ALT_SYNC_ARGS_FILE:-}" ]] && _as_env+=("ALT_SYNC_ARGS_FILE=$ALT_SYNC_ARGS_FILE")
    [[ -n "${ALT_SYNC_LOG_FILE:-}" ]] && _as_env+=("ALT_SYNC_LOG_FILE=$ALT_SYNC_LOG_FILE")
    [[ -n "${ALT_SYNC_CANCEL_FLAG:-}" ]] && _as_env+=("ALT_SYNC_CANCEL_FLAG=$ALT_SYNC_CANCEL_FLAG")
    [[ -n "${ALT_SYNC_READY_FILE:-}" ]] && _as_env+=("ALT_SYNC_READY_FILE=$ALT_SYNC_READY_FILE")
    [[ -n "${ALT_SYNC_LOG_FILE:-}" ]] && _as_env+=("--log-file" "$ALT_SYNC_LOG_FILE")
    [[ -n "${ALT_SYNC_CANCEL_FLAG:-}" ]] && _as_env+=("--cancel-flag" "$ALT_SYNC_CANCEL_FLAG")
    unset _lfclean _lfskip _lfa

    for _v in "$SELF" "${_as_env[@]}" "$@"; do
        if [[ "$_v" == *"'"* ]]; then
            printf 'Некорректный символ (одинарная кавычка) в пути/параметрах запуска: %s\n' "$_v" >&2
            exit 1
        fi
    done
    unset _v

    ORIG_LOGIN="$(id -un 2>/dev/null || true)"
    if [[ -n "$ORIG_LOGIN" && "$ORIG_LOGIN" != "root" ]]; then
        _as_env+=("ALT_SYNC_ORIG_USER=$ORIG_LOGIN")
    fi
    unset ORIG_LOGIN

    if command -v sudo >/dev/null 2>&1; then
        _gui_ask=0
        [[ "${ALT_SYNC_GUI:-0}" == "1" ]] && _gui_ask=1
        if (( _gui_ask )); then
            _cmd="env"
            for _e in "${_as_env[@]}"; do _cmd+=" $(printf '%q' "$_e")"; done
            [[ -n "$(id -un 2>/dev/null || true)" && "$(id -un)" != "root" ]] \
                && _cmd+=" $(printf '%q' "SUDO_USER=$(id -un)")"
            [[ "$(id -u)" != "0" ]] && _cmd+=" $(printf '%q' "SUDO_UID=$(id -u)") $(printf '%q' "SUDO_GID=$(id -g)")"
            _cmd+=" bash $(printf '%q' "$SELF")"
            for _a in "$@"; do _cmd+=" $(printf '%q' "$_a")"; done
            _gready="${ALT_SYNC_READY_FILE:-${TMPDIR:-/tmp}/alt_sync_ready.$$.tmp}"
            _cmd+=" $(printf '%q' "ALT_SYNC_READY_FILE=$_gready")"
            sudo_pipe_as_root "$_cmd"
            _sr=$?
            [[ -n "${ALT_SYNC_READY_FILE:-}" ]] || rm -f "$_gready" 2>/dev/null || true
            case $_sr in
                0) ;;
                10) printf 'Ввод пароля отменён (диалог закрыт или поле осталось пустым).\n' >&2; exit 1 ;;
                11) printf 'Пароль администратора не принят (или нет прав sudo).\n' >&2; exit 1 ;;
                *)  exit $_sr ;;
            esac
            exit 0
        fi
        printf 'Запрашиваю права root через sudo... (введите пароль при запросе)\n' >&2
        exec sudo "${_as_env[@]}" bash "$SELF" "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        printf 'Запрашиваю права root через pkexec...\n' >&2
        exec pkexec env DISPLAY="${DISPLAY:-:0}" XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}" \
             "${_as_env[@]}" bash "$SELF" "$@"
    elif command -v su >/dev/null 2>&1; then
        printf 'Запрашиваю права root через su...\n' >&2
        _sucmd="env"
        for _e in "${_as_env[@]}"; do _sucmd+=" $(printf '%q' "$_e")"; done
        _sucmd+=" bash $(printf '%q' "$SELF")"
        for _a in "$@"; do _sucmd+=" $(printf '%q' "$_a")"; done
        exec su -c "$_sucmd" root
    else
        printf 'Нужен root. Запустите: su -c "bash %s"\n' "$SELF" >&2
        exit 1
    fi
fi

if (($# > 0)); then
    for _hubd in "${AS_HUB_DIRS[@]}" "$SCRIPT_DIR/.alt-sync-hub"; do
        mkdir -p "$_hubd" 2>/dev/null || continue
        printf '%s\n' "$@" >"$_hubd/args.txt" 2>/dev/null && chmod a+rw "$_hubd/args.txt" 2>/dev/null || true
        [[ -f "$_hubd/args.txt" ]] && printf '%s %s\n' "$(date +%s)" "$(id -u)" >"$_hubd/args.stamp" 2>/dev/null && chmod a+rw "$_hubd/args.stamp" 2>/dev/null || true
    done
fi

_alt_sync_hub_fresh() {
    local _st="${1%/*}/args.stamp" _now _age _t _u
    if [[ -r "$_st" ]]; then
        read -r _t _u <"$_st" || { _t=""; _u=""; }
        if [[ "$_t" =~ ^[0-9]+$ ]]; then
            _now=$(date +%s); _age=$((_now - _t))
            (( _age >= 0 && _age < 300 )) && return 0
            return 1
        fi
    fi
    [[ -f "$1" ]] || return 1
    _t=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "")
    [[ "$_t" =~ ^[0-9]+$ ]] || return 1
    _now=$(date +%s); _age=$((_now - _t))
    (( _age >= 0 && _age < 300 ))
}
if [[ $# -eq 0 ]]; then
    for _hubf in "${AS_HUB_DIRS[0]}/args.txt" "/run/alt-sync/args.txt" \
                 "$SCRIPT_DIR/.alt-sync-hub/args.txt" "${TMPDIR:-/tmp}/alt-sync-hub.$(id -u)/args.txt"; do
        [[ -n "$_hubf" && -r "$_hubf" ]] || continue
        _alt_sync_hub_fresh "$_hubf" || { printf '%s INFO: Хаб-канал %s устарел (>5 мин) — пропускаю.\n' "$(date '+%F %T')" "$_hubf" >&2; continue; }
        _hub_args=()
        while IFS= read -r _hl; do
            [[ -z "$_hl" ]] && continue
            _hub_args+=("$_hl")
        done <"$_hubf"
        if ((${#_hub_args[@]} > 0)); then
            set -- "${_hub_args[@]}"
            printf '%s INFO: Задача восстановлена из хаба (%s): %s\n' "$(date '+%F %T')" "$_hubf" "$*" >&2
            break
        fi
        unset _hub_args
    done
    unset _hubf _hl
fi

NONINTERACTIVE="${ALT_SYNC_NONINTERACTIVE:-0}"
if [[ "${ALT_SYNC_ASSUME_YES:-0}" == "1" ]]; then
    NONINTERACTIVE=1
fi

for _pre_arg in "$@"; do
    case "$_pre_arg" in
        -h|--help)
            printf 'ALT Linux Universal Sync v%s\n' "$SCRIPT_VERSION"
            printf 'Интерактив:  %s\n' "$SELF"
            printf 'CLI:         %s <export|export-offline|import|import-offline|cryptopro|verify|fetch-deps> [-y|--yes | --defaults] [--user NAME] [--backup-dir DIR]\n' "$SELF"
            printf 'Env:         ALT_SYNC_NONINTERACTIVE=1, ALT_SYNC_TARGET_USER=name, ALT_SYNC_BACKUP_DIR=DIR, NO_COLOR=1\n'
            printf 'Логи:        рядом со скриптом (%s); при недоступности — ./logs, затем /tmp\n' "$(dirname "$SELF")"
            printf '(Полная справка — в интерактивном/CLI-режиме от root.)\n'
            exit 0
            ;;
    esac
done
unset _pre_arg

if (($# > 0)); then
    _cn_in=("$@"); _cn_out=(); _cn_changed=0
    for _cn_a in "${_cn_in[@]}"; do
        if [[ "$_cn_a" =~ ^[A-Za-z0-9+/=]{8,}$ ]]; then
            _cn_dec="$(printf '%s' "$_cn_a" | base64 -d 2>/dev/null)" || { _cn_out+=("$_cn_a"); continue; }
            if [[ "$(printf '%s' "$_cn_dec" | base64 | tr -d '\n')" == "$_cn_a" ]]; then
                while IFS= read -r _cn_line; do
                    [[ -z "$_cn_line" ]] && continue
                    _cn_out+=("$_cn_line")
                done <<<"$_cn_dec"
                _cn_changed=1
                continue
            fi
        fi
        _cn_out+=("$_cn_a")
    done
    if (( _cn_changed )) && ((${#_cn_out[@]} > 0)); then
        set -- "${_cn_out[@]}"
        printf '%s INFO: Аргументы задачи восстановлены из base64-формата (защита от двойной передачи cmdline+env).\n' "$(date '+%F %T')" >&2
    fi
    unset _cn_in _cn_out _cn_a _cn_dec _cn_line _cn_changed
fi

alt_sync_read_args_channel() {
    local f="${ALT_SYNC_ARGS_FILE:-}"
    [[ -n "$f" && -r "$f" ]] || return 0
    cat -- "$f" 2>/dev/null || true
}

alt_sync_merge_args() {
    local -a src=("$@") _l
    while IFS= read -r _l; do
        [[ -z "$_l" ]] && continue
        src+=("$_l")
    done < <(alt_sync_read_args_channel; \
             if [[ -n "${ALT_SYNC_ARGS_B64:-}" ]]; then
                 printf '%s\n' "$ALT_SYNC_ARGS_B64" | sed 's/.\{76\}/&\n/g' \
                   | while IFS= read -r _b; do [[ -z "$_b" ]] && continue
                       printf '%s\n' "$_b" | base64 -d 2>/dev/null | awk 'NR==1'; done
             fi)
    local -a flat=()
    for _l in "${src[@]}"; do
        case "$_l" in
            "--user "*)      flat+=("--user" "${_l#--user }") ;;
            "--backup-dir "*) flat+=("--backup-dir" "${_l#--backup-dir }") ;;
            *)               flat+=("$_l") ;;
        esac
    done
    local -a out=(); local seen="|" x
    for x in "${flat[@]}"; do
        [[ "$seen" == *"|$x|"* ]] && continue
        out+=("$x"); seen+="|${x}|"
    done
    ((${#out[@]})) && printf '%s\n' "${out[@]}"
}

_alt_sync_action_seen=""
while IFS= read -r _aa; do
    case "$_aa" in
        export|export-offline|import|import-offline|cryptopro|verify|fetch-deps)
            _alt_sync_action_seen="$_aa" ;;
    esac
done < <(alt_sync_merge_args "$@" 2>/dev/null || true)
if [[ -n "${ALT_SYNC_ARGS_FILE:-}" && ! -s "${ALT_SYNC_ARGS_FILE:-/nonexistent}" \
    && -n "$_alt_sync_action_seen" ]]; then
    printf '%s\n' "$_alt_sync_action_seen" >"$ALT_SYNC_ARGS_FILE" 2>/dev/null || true
fi
unset _alt_sync_action_seen _aa

if [[ -n "${ALT_SYNC_ARGS_FILE:-}${ALT_SYNC_ARGS_B64:-}" \
    && ( "${ALT_SYNC_GUI:-0}" == "1" || "${ALT_SYNC_NONINTERACTIVE:-0}" == "1" ) ]]; then
    _relay_args=()
    while IFS= read -r _ra; do
        [[ -z "$_ra" ]] && continue
        _relay_args+=("$_ra")
    done < <(alt_sync_merge_args "$@")
    ((${#_relay_args[@]} > 0)) && set -- "${_relay_args[@]}"
    unset _relay_args _ra _b64line ALT_SYNC_ARGS_B64
fi

if [[ $EUID -eq 0 ]]; then
    if [[ $# -eq 0 && -n "${ALT_SYNC_ARGS_FILE:-}" && -r "${ALT_SYNC_ARGS_FILE:-/nonexistent}" ]] \
        && [[ "${ALT_SYNC_GUI:-0}" == "1" || "${ALT_SYNC_NONINTERACTIVE:-0}" == "1" ]]; then
        _fc_args=()
        while IFS= read -r _fc_l; do
            [[ -z "$_fc_l" ]] && continue
            _fc_args+=("$_fc_l")
        done <"$ALT_SYNC_ARGS_FILE"
        if ((${#_fc_args[@]} > 0)); then
            set -- "${_fc_args[@]}"
            printf '%s INFO: Действие восстановлено из файла-канала задачи (%s).\n' "$(date '+%F %T')" "$1" >&2
        fi
        unset _fc_args _fc_l
    fi
    for _a in "$@"; do
        case "$_a" in
            export|export-offline|import|import-offline|cryptopro|verify|fetch-deps)
                if [[ "${ALT_SYNC_GUI:-0}" != "1" ]]; then
                    ALT_SYNC_GUI=1; export ALT_SYNC_GUI
                    printf '%s INFO: Режим GUI восстановлен из аргументов задачи (%s).\n' "$(date '+%F %T')" "$_a" >&2
                fi
                break ;;
        esac
    done
    unset _a
    if [[ $# -eq 0 ]]; then
        _la=""; _lt=""; _lc=""
        for _lf in "/run/alt-sync/gui.last.log" "/tmp/alt-sync-gui.last.log" \
                   "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _lc=$(tail -20 "$_lf" 2>/dev/null \
                  | grep -a ' задача cli=' | tail -1 \
                  | sed -nE 's/.*cli=([^ ]+) .*/\1/p')
            _la=$(tail -20 "$_lf" 2>/dev/null \
                  | grep -a ' задача cli=' | tail -1 \
                  | sed -nE 's/.*cli=[^ ]+ [^ ]*=(.*) пользователь=.*/\1/p')
            [[ -n "$_la" ]] && break
        done
        if [[ -n "$_la" ]]; then
            set -- $_la
            case "${1:-}" in
                export|export-offline|import|import-offline|cryptopro|verify|fetch-deps) : ;;
                *)  case "$_lc" in
                        export|export-offline|import|import-offline|cryptopro|verify|fetch-deps)
                            set -- "$_lc" "$@" ;;
                    esac ;;
            esac
            printf '%s INFO: Действие восстановлено из следа GUI (точная CLI-строка): %s\n' "$(date '+%F %T')" "$*" >&2
        else
        _tt="$(gui_task_trace_read)" || _tt=""
        if [[ -n "${_tt// /}" ]]; then
            set -- $_tt
            printf '%s INFO: Действие восстановлено из следа задачи: %s\n' "$(date '+%F %T')" "$*" >&2
        else
        for _lf in "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _la=$(tail -5 "$_lf" 2>/dev/null \
                  | grep -a 'форма rc=0' | tail -1 \
                  | sed -nE 's/.*вывод="([^"|]*)\|.*/\1/p')
            [[ -n "$_la" ]] && break
        done
        for _lf in "$SCRIPT_DIR/alt_sync_gui.last.log" "$SCRIPT_DIR/logs/alt_sync_gui.last.log"; do
            [[ -f "$_lf" ]] || continue
            _lt=$(tail -5 "$_lf" 2>/dev/null \
                  | grep -a 'форма rc=0' | tail -1 \
                  | sed -nE 's/.*вывод="[^|]*\|([^|]*)\|.*/\1/p')
            [[ -n "$_lt" ]] && break
        done
        case "$_la" in
            *локальн*|*без\ сети*) set -- export-offline --yes ;;
            *Экспорт\ эталона*)    set -- export --yes ;;
            *Импорт*)
                if [[ "$_la" == *офлайн* ]]; then set -- import-offline --yes
                else set -- import --defaults; fi ;;
            *CryptoPro*|*cryptopro*) set -- cryptopro --yes ;;
            *Проверка*|*целостность*|*verify*) set -- verify --yes ;;
            *компонент*|*Зависимост*|*fetch*)  set -- fetch-deps --yes ;;
            *)
                case "$_lt" in
                    WIFI)   set -- export-offline --yes ;;
                    *)      set -- export --yes ;;
                esac ;;
        esac
        [[ $# -gt 0 ]] && printf '%s INFO: Действие восстановлено из следа GUI (метка: %s): %s\n' "$(date '+%F %T')" "$_la" "$*" >&2
        fi
        fi
        unset _la _lt _lf _tt
    fi
    [[ "${ALT_SYNC_NONINTERACTIVE:-0}" == "1" ]] || {
        for _f in "$@"; do
            case "$_f" in -y|--yes|--defaults)
                ALT_SYNC_NONINTERACTIVE=1; export ALT_SYNC_NONINTERACTIVE
                break ;;
            esac
        done
        unset _f
    }
    if [[ "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        [[ "${ALT_SYNC_NONINTERACTIVE:-0}" == "1" ]] || {
            ALT_SYNC_NONINTERACTIVE=1; export ALT_SYNC_NONINTERACTIVE
        }
    fi
fi

if [[ $EUID -eq 0 && -z "${ALT_SYNC_TARGET_USER:-}" ]]; then
    _tu_prev=""
    for _tu in "$@"; do
        if [[ "$_tu_prev" == "--user" ]]; then ALT_SYNC_TARGET_USER="$_tu"; export ALT_SYNC_TARGET_USER; break; fi
        _tu_prev="$_tu"
    done
    unset _tu _tu_prev
fi
OPT_NETWORK_ENABLED=0
OPT_DOWNLOAD_MISSING=0
OPT_USE_NETWORK_IMPORT=0

OPT_VERIFY_BACKUP=1
OPT_SNAPSHOT=1

OPT_BACKUP_USER=1
OPT_RESTORE_USER=1
OPT_SKIP_MOZILLA=1

OPT_FORCE_EPM_PLAY=0
OPT_FORCE_CRYPTO_INSTALLER=0
OPT_ALLOW_NODEPS=0

OPT_SKIP_VENDOR_ASSETS=0
OPT_SKIP_VENDOR_RESTORE=0
OPT_BACKUP_NETWORK_KEYS="${ALT_SYNC_BACKUP_NETWORK_KEYS:-0}"
if [[ "${ALT_SYNC_BACKUP_MOZILLA:-0}" == "1" ]]; then OPT_SKIP_MOZILLA=0; fi

SYSTEM_LISTS_UPDATED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

if [[ -n "${ALT_SYNC_SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$ALT_SYNC_SCRIPT_DIR"
fi
LOG_DIR="$SCRIPT_DIR/logs"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || ! : >> "$LOG_DIR/.write_test" 2>/dev/null; then
    rm -f "$LOG_DIR/.write_test" 2>/dev/null || true
    LOG_DIR="${TMPDIR:-/tmp}/alt-sync-log"
    mkdir -p "$LOG_DIR" 2>/dev/null || {
        printf 'Не удалось создать папку логов: %s\n' "$LOG_DIR" >&2
        exit 1
    }
else
    rm -f "$LOG_DIR/.write_test" 2>/dev/null || true
fi

LOG_FILE="${ALT_SYNC_LOG_FILE:-}"
if [[ -z "$LOG_FILE" ]]; then
    for _lpb in "${ALT_SYNC_SCRIPT_DIR:-$SCRIPT_DIR}/.alt_sync_live.path" \
                "$SCRIPT_DIR/.alt_sync_live.path" "/run/alt-sync/log.path" \
                "${TMPDIR:-/tmp}/alt-sync-hub.$(id -u)/log.path" \
                "${TMPDIR:-/tmp}/alt-sync-hub.0/log.path"; do
        [[ -f "$_lpb" ]] || continue
        _lpc="$(head -1 "$_lpb" 2>/dev/null)"
        [[ -n "$_lpc" && -e "$_lpc" ]] && { LOG_FILE="$_lpc"; break; }
    done
    unset _lpb _lpc
fi
if [[ -n "$LOG_FILE" ]]; then
    case "$LOG_FILE" in
        "$LOG_DIR/"*) : ;;
        *) printf '%s WARN: маяк лога %s вне папки логов %s — игнорирую, создаю новый.\n' \
                "$(date '+%F %T')" "$LOG_FILE" "$LOG_DIR" >&2
           LOG_FILE="" ;;
    esac
fi
if [[ -n "$LOG_FILE" ]] && ! : >> "$LOG_FILE" 2>/dev/null; then
    printf '%s WARN: переданный лог %s недоступен на запись (права/SELinux) — создаю новый.\n' \
        "$(date '+%F %T')" "$LOG_FILE" >&2
    LOG_FILE=""
fi
if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$LOG_DIR/alt_sync_$(date +%Y%m%d_%H%M%S)_$$.log"
    : >> "$LOG_FILE" 2>/dev/null || {
        LOG_FILE="${TMPDIR:-/tmp}/alt-sync-log/alt_sync_$(date +%Y%m%d_%H%M%S)_$$.log"
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        : >> "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/alt_sync_$(date +%Y%m%d_%H%M%S)_$$.log"
        : >> "$LOG_FILE" 2>/dev/null || { printf 'Не удалось создать файл лога\n' >&2; exit 1; }
    }
fi
REPORT_DIR="$LOG_DIR"
_as_log_beacons() {
    local _lp="${ALT_SYNC_LOG_FILE:-$LOG_FILE}" _hubd _bp _own=""
    [[ -n "$_lp" ]] || return 0
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        _own="$SUDO_UID:$SUDO_GID"
    elif [[ -n "${GUI_OWNER_UID:-}" ]]; then
        _own="$GUI_OWNER_UID:${GUI_OWNER_GID:-$GUI_OWNER_UID}"
    fi
    if [[ "$EUID" -eq 0 ]]; then
        if [[ -n "$_own" ]]; then
            chown "$_own" "$_lp" 2>/dev/null || true
        else
            _og=$(stat -c '%u:%g' "/proc/1" 2>/dev/null)
            [[ -n "${_og:-}" && "$_og" != "0:0" ]] && chown "$_og" "$_lp" 2>/dev/null || true
        fi
        chmod a+r "$_lp" 2>/dev/null || true
    fi
    if [[ -n "${AS_LOGBEACON:-}" ]]; then
        printf '%s\n' "$_lp" >"$AS_LOGBEACON" 2>/dev/null || true
        chmod a+r "$AS_LOGBEACON" 2>/dev/null || true
    fi
    for _hubd in "/run/alt-sync" "${TMPDIR:-/tmp}/alt-sync-hub.$(id -u)" "${TMPDIR:-/tmp}/alt-sync-hub.0"; do
        mkdir -p "$_hubd" 2>/dev/null || continue
        _bp="$_hubd/log.path"
        printf '%s\n' "$_lp" >"$_bp" 2>/dev/null && chmod a+rw "$_bp" 2>/dev/null || true
    done
    return 0
}
export ALT_SYNC_LOG_FILE="$LOG_FILE"
_as_log_beacons
chmod a+rw "$LOG_FILE" 2>/dev/null || true
ln -sf "$LOG_FILE" "$LOG_DIR/alt_sync_latest.log" 2>/dev/null || true
if ln -sfn "$LOG_FILE" /run/alt_sync_latest.log 2>/dev/null; then
    chmod a+r /run/alt_sync_latest.log 2>/dev/null || true
fi

if ! : >> "$LOG_FILE" 2>/dev/null; then
    printf 'Не удалось создать файл лога: %s\n' "$LOG_FILE" >&2
    exit 1
fi

GUI_CHOWN_OWNER=""
if [[ "${ALT_SYNC_GUI:-0}" == "1" && "$EUID" -eq 0 ]]; then
    if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] && [[ "${SUDO_GID:-}" =~ ^[0-9]+$ ]]; then
        GUI_CHOWN_OWNER="${SUDO_UID}:${SUDO_GID}"
    else
        _gu="${ALT_SYNC_TARGET_USER:-$(detect_default_user 2>/dev/null || true)}"
        if [[ -n "$_gu" ]] && id "$_gu" >/dev/null 2>&1; then
            GUI_CHOWN_OWNER="$(id -u "$_gu"):$(id -g "$_gu")"
        fi
        unset _gu
    fi
    if [[ -n "$GUI_CHOWN_OWNER" ]]; then
        chown "$GUI_CHOWN_OWNER" "$LOG_DIR" 2>/dev/null || true
        chmod a+rwx "$LOG_FILE" 2>/dev/null || true
    fi
fi

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
    if command -v sync >/dev/null 2>&1; then
        case "$*" in
            PROGRESS\|*|STEP\ *|INIT:*|FATAL:*|ERROR:*) sync ;;
        esac
    fi
}

log "INIT: alt_sync v$SCRIPT_VERSION запущен (pid=$$, uid=$(id -u), лог=$LOG_FILE)"

if [[ -t 1 && -r /dev/tty && -w /dev/tty ]] && command -v sed >/dev/null 2>&1; then
    exec 3>&1
    exec > >(sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b\[K//g' \
              | tee -a "$LOG_FILE" >&3) 2>&1
else
    if command -v sed >/dev/null 2>&1; then
        exec > >(sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b\[K//g' >> "$LOG_FILE") 2>&1
    else
        exec >> "$LOG_FILE" 2>&1
    fi
fi
INPUT_TTY=""
if [[ -t 0 ]] && [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
    INPUT_TTY="/dev/tty"
fi
if [[ -n "$INPUT_TTY" ]]; then
    { exec 3<"$INPUT_TTY"; } 2>/dev/null || { exec 3</dev/null; } 2>/dev/null || true
else
    { exec 3</dev/null; } 2>/dev/null || true
fi
export INPUT_TTY

_finish_log() {
    local rc=$?
    printf '%s INFO: Завершение работы (exit code %s)\n' "$(date '+%F %T')" "$rc" >> "$LOG_FILE" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap _finish_log EXIT

_alt_sync_signal_ready() {
    [[ "${ALT_SYNC_GUI:-0}" == "1" ]] || return 0
    local _rf
    for _rf in "${ALT_SYNC_READY_FILE:-}" "$AS_READY_FILE" "${TMPDIR:-/tmp}/alt_sync_ready.$$.tmp"; do
        [[ -n "$_rf" ]] || continue
        printf '%s\n' "$$" > "$_rf" 2>/dev/null || true
    done
}
_alt_sync_signal_ready
gui_task_trace_write "$@"

die() {
    printf '%b\n' "${RED}❌ $*${NC}" >&2
    log "FATAL: $*"
    exit 1
}

TOTAL_STEPS=0
CURRENT_STEP=0
START_TIME=0

declare -a REPORT_OK_LIST=()
declare -a REPORT_WARN_LIST=()
declare -a REPORT_FAIL_LIST=()

report_note_ok()   { REPORT_OK_LIST+=("$1"); }
report_note_warn() { REPORT_WARN_LIST+=("$1"); }
report_note_fail() { REPORT_FAIL_LIST+=("$1"); }

init_steps() {
    TOTAL_STEPS="$1"
    CURRENT_STEP=0
    START_TIME="$(date +%s)"
}

elapsed_string() {
    local e
    e=$(( $(date +%s) - START_TIME ))
    if (( e >= 3600 )); then
        printf '%02d:%02d:%02d' $((e / 3600)) $((e % 3600 / 60)) $((e % 60))
    else
        printf '%02d:%02d' $((e / 60)) $((e % 60))
    fi
}

step_start() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    gui_cancel_check "перед шагом: $1"
    printf "\n${BLUE}━━━ Шаг %d/%d [%s] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" \
        "$CURRENT_STEP" "$TOTAL_STEPS" "$(elapsed_string)"
    printf "${BOLD}▶ %s${NC}\n" "$1"
    log "STEP $CURRENT_STEP/$TOTAL_STEPS: $1"
    local _spct=0
    if (( TOTAL_STEPS > 0 )); then
        _spct=$(( (CURRENT_STEP - 1) * 100 / TOTAL_STEPS ))
        (( _spct > 99 )) && _spct=99
    fi
    local _plist=""
    [[ -f "$LISTS_DIR/installed_nvra.txt" ]] && _plist="$LISTS_DIR/installed_nvra.txt"
    log "PROGRESS|step=$CURRENT_STEP|$TOTAL_STEPS|${_plist}|pct=$_spct|$1"
    ( _as_log_beacons 2>/dev/null; ln -sf "$LOG_FILE" "$LOG_DIR/alt_sync_latest.log" 2>/dev/null ) &
}

gui_cancel_requested() { [[ -n "${ALT_SYNC_CANCEL_FLAG:-}" && -e "$ALT_SYNC_CANCEL_FLAG" ]]; }
gui_cancel_check() {
    gui_cancel_requested || return 0
    log "CANCEL: задача прервана по кнопке «Отмена» (${1:-})"
    printf '\n%s\n' "⛔ Отменено пользователем (${1:-}). Выполняется откат временных данных…"
    CANCELLED_BY_USER=1
    exit 130
}

step_ok() {
    printf "${GREEN}  ✅ %s${NC}\n" "${1:-Готово}"
    log "OK: ${1:-Готово}"
    report_note_ok "${1:-Готово}"
}

step_warn() {
    printf "${YELLOW}  ⚠️  %s${NC}\n" "$1"
    log "WARN: $1"
    report_note_warn "$1"
}

step_fail() {
    printf "${RED}  ❌ %s${NC}\n" "$1"
    log "FAIL: $1"
    report_note_fail "$1"
    return 1
}

info() {
    printf "${CYAN}  ℹ️  %s${NC}\n" "$1"
    log "INFO: $1"
}

warn() {
    step_warn "$*"
}

ask_yes_no() {
    local prompt="$1"
    local def="${2:-n}"
    local hint ans

    if [[ "$def" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi

    printf '%s %s ' "$prompt" "$hint"

    if [[ "$NONINTERACTIVE" == "1" ]] || [[ ! -t 0 ]]; then
        local eff="$def"
        if [[ "${ALT_SYNC_ASSUME_YES:-0}" == "1" ]]; then
            eff="y"
        fi
        printf '(неинтерактивный режим: %s)\n' "$([[ "$eff" == "y" ]] && echo "yes" || echo "no")"
        log "ASK(auto): $prompt -> $eff"
        if [[ "$eff" == "y" ]]; then
            return 0
        fi
        return 1
    fi

    local rc=0 ans_is_eof=0
    if ! IFS= read -r ans; then
        rc=$?
        printf '\n'
        if (( rc > 1 )); then
            ans="$def"
            ans_is_eof=1
        fi
    else
        ans="${ans:-}"
    fi

    ans="${ans//[[:space:]]/}"
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"

    case "$ans" in
        y|yes|д|да|1)
            return 0
            ;;
        n|no|н|нет|0)
            return 1
            ;;
        "")
            if [[ "$def" == "y" ]]; then
                return 0
            else
                return 1
            fi
            ;;
        *)
            if (( ans_is_eof == 0 )) && [[ -t 0 ]]; then
                printf '%b\n' "${YELLOW}  Введите «да»/«нет» (y/n), пустая строка — по умолчанию.${NC}"
                ask_yes_no "$prompt" "$def"
                return $?
            fi
            return 1
            ;;
    esac
}

LAST_PROGRESS_PCT=-1

progress_reset() {
    LAST_PROGRESS_PCT=-1
}

progress_bar() {
    local current="$1"
    local total="${2:-1}"
    local label="${3:-}"
    local item="${4:-}"

    if (( total <= 0 )); then
        total=1
    fi

    local pct=$(( current * 100 / total ))
    if (( pct > 100 )); then
        pct=100
    fi

    gui_cancel_requested && gui_cancel_check "во время: $label"

    if (( pct != LAST_PROGRESS_PCT )); then
        log "$label $current/$total (${pct}%)"
        local _lbl="$label"
        [[ -n "$item" ]] && _lbl="$label [$item]"
        log "PROGRESS|detail|$current|$total|pct=$pct|$_lbl"
        LAST_PROGRESS_PCT="$pct"
    fi

    if [[ -t 1 ]]; then
        local width=32
        local filled=$(( current * width / total ))
        if (( filled > width )); then filled=width; fi
        if (( filled < 0 )); then filled=0; fi

        local empty=$(( width - filled ))

        local bar_filled bar_empty
        bar_filled="$(printf '%*s' "$filled" '')"
        bar_filled="${bar_filled// /#}"

        bar_empty="$(printf '%*s' "$empty" '')"
        bar_empty="${bar_empty// /-}"

        printf '\r%s [%3d%%] %s%s %d/%d' \
            "$label" "$pct" "$bar_filled" "$bar_empty" "$current" "$total"

        if (( current >= total )); then
            printf '\n'
        fi
    fi
}

CACHE_DIR="/var/cache/apt/archives"

if [[ -n "${ALT_SYNC_BACKUP_DIR:-}" ]]; then
    BACKUP_DIR="$ALT_SYNC_BACKUP_DIR"
elif [[ -d "$SCRIPT_DIR/lists" && -d "$SCRIPT_DIR/packages" ]]; then
    BACKUP_DIR="$SCRIPT_DIR"
elif [[ -d "$SCRIPT_DIR/alt_backup/lists" && -d "$SCRIPT_DIR/alt_backup/packages" ]]; then
    BACKUP_DIR="$SCRIPT_DIR/alt_backup"
else
    BACKUP_DIR="$SCRIPT_DIR/alt_backup"
fi

if [[ "$BACKUP_DIR" == "/" ]]; then
    die "BACKUP_DIR не может быть /. Это опасно."
fi

LISTS_DIR="$BACKUP_DIR/lists"
PACKAGES_DIR="$BACKUP_DIR/packages"
CONFIGS_DIR="$BACKUP_DIR/configs"
ASSETS_DIR="$BACKUP_DIR/assets"
MACHINE_ID_FILE="$BACKUP_DIR/.machine_id"
INSTALL_DIR="${SCRIPT_DIR}/install"

if [[ -n "${GUI_CHOWN_OWNER:-}" && ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR" 2>/dev/null && chown "$GUI_CHOWN_OWNER" "$BACKUP_DIR" 2>/dev/null || true
fi

TARGET_USER=""
HOME_DIR=""
TARGET_GROUP=""

have_cmd() { command -v "$1" >/dev/null 2>&1; }

REQUIRED_CORE_UTILS=(find sort tar awk sed grep date getent sleep wc cut tr
                     dirname basename mkdir rm cp chmod touch cat xargs id
                     mktemp hostname uname du mv sha256sum)

DEPENDENCY_SPECS=(
    "rpm|rpm"
    "apt-get|apt"
    "flock|util-linux"
    "gzip|gzip"
    "bzip2|bzip2"
    "xz|xz-utils"
    "zstd|zstd"
    "timeout|coreutils"
    "unrar|unrar"
    "unar|unar"
    "bsdtar|libarchive-tools"
    "7z|p7zip"
    "7za|p7zip"
    "unzip|unzip"
    "epm|epm"
    "whiptail|dialog"
    "pkexec|polkit"
    "notify-send|libnotify"
    "yad|yad"
    "zenity|zenity"
    "qarma|qarma"
    "kdialog|kdialog"
)

pkg_for_cmd() {
    local spec c p
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        [[ "$c" == "$1" ]] && { printf '%s' "$p"; return 0; }
    done
    printf '%s' "$1"
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        if ! have_cmd "$cmd"; then
            die "Требуется команда: $cmd"
        fi
    done
}

require_commands "${REQUIRED_CORE_UTILS[@]}"

HAVE_FLOCK=1; have_cmd flock || HAVE_FLOCK=0
MISSING_BOOTSTRAP=()
for _cmd in rpm apt-get; do
    have_cmd "$_cmd" || MISSING_BOOTSTRAP+=("$_cmd")
done
unset _cmd

OPTIONAL_COMMANDS=(gzip bzip2 xz zstd timeout unrar unar bsdtar 7z 7za unzip epm whiptail systemctl ldconfig udevadm pkexec notify-send yad zenity qarma kdialog)
MISSING_OPTIONAL_COMMANDS=()
for _cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if ! have_cmd "$_cmd"; then
        MISSING_OPTIONAL_COMMANDS+=("$_cmd")
    fi
done
unset _cmd

__widget_missing=0
for _w in yad zenity qarma kdialog; do
    [[ " ${MISSING_OPTIONAL_COMMANDS[*]:-} " == *" $_w "* ]] && __widget_missing=$((__widget_missing+1))
done
if (( __widget_missing > 0 )) && have_cmd yad; then __widget_missing=0
elif (( __widget_missing > 0 )) && have_cmd zenity; then __widget_missing=0
elif (( __widget_missing > 0 )); then __widget_missing=1; fi
if (( __widget_missing <= 1 )); then
    __kept=()
    for _cmd in "${MISSING_OPTIONAL_COMMANDS[@]}"; do
        case "$_cmd" in yad|zenity|qarma|kdialog) ;; *) __kept+=("$_cmd") ;; esac
    done
    if ((${#__kept[@]} < ${#MISSING_OPTIONAL_COMMANDS[@]})); then
        for _w in yad zenity qarma kdialog; do
            [[ " ${MISSING_OPTIONAL_COMMANDS[*]:-} " == *" $_w "* ]] && { __kept+=("$_w"); break; }
        done
    fi
    MISSING_OPTIONAL_COMMANDS=("${__kept[@]:-}")
    unset __kept
fi
__arch_found=0
for _a in 7z 7za unar bsdtar unrar; do have_cmd "$_a" && { __arch_found=1; break; }; done
if (( __arch_found )); then
    __kept=()
    for _cmd in "${MISSING_OPTIONAL_COMMANDS[@]}"; do
        case "$_cmd" in 7z|7za|unar|bsdtar|unrar) ;; *) __kept+=("$_cmd") ;; esac
    done
    MISSING_OPTIONAL_COMMANDS=("${__kept[@]:-}")
    unset __kept
fi
unset __arch_found __widget_missing _w _a

if ((${#MISSING_OPTIONAL_COMMANDS[@]} > 0)); then
    log "INFO: Нет опциональных команд: ${MISSING_OPTIONAL_COMMANDS[*]} (будут использованы fallback-механизмы)"
fi

LOCK_DIR="/run/lock"
if [[ ! -d "$LOCK_DIR" ]]; then
    LOCK_DIR="/var/lock"
fi
if [[ ! -d "$LOCK_DIR" ]]; then
    LOCK_DIR="${TMPDIR:-/tmp}"
fi

mkdir -p "$LOCK_DIR" 2>/dev/null || LOCK_DIR="${TMPDIR:-/tmp}"
LOCK_FILE="$LOCK_DIR/alt-sync.lock"

if ! touch "$LOCK_FILE" 2>/dev/null; then
    die "Не удалось создать lock-файл: $LOCK_FILE"
fi

exec 9>"$LOCK_FILE"
if (( HAVE_FLOCK == 1 )); then
    flock -n 9 || die "Другой экземпляр alt_sync уже запущен (замок: $LOCK_FILE). Дождитесь его завершения."
else
    printf '%s\n' "$$" >&9 2>/dev/null || true
    log "WARN: flock недоступен — блокировка от параллельного запуска ослаблена (PID-файл: $LOCK_FILE)."
fi

EPSON_PKGS=(
    epsonscan2
    imagescan-sane
    iscan-free
    iscan-data
    firmware-iscan
)

PANTUM_PKGS=(
    epm
    whiptail
    newt
)

CRYPTO_PKGS=(
    cryptopro-preinstall
)

VENDOR_NAME_GLOBS=(
    '*pantum*'
    '*epson*'
    '*iscan*'
    '*imagescan*'
    '*cprocsp*'
    '*cryptopro*'
    '*crypto-pro*'
)

VENDOR_FIXED_PATHS=(
    etc/pantum
    etc/epson
    etc/iscan
    etc/imagescan
    etc/cryptopro
    etc/opt/cprocsp

    usr/lib/pantum
    usr/lib64/pantum
    usr/share/pantum

    var/lib/pantum
)

VENDOR_SEARCH_ROOTS=(
    opt
    etc

    etc/systemd/system
    etc/ld.so.conf.d
    etc/profile.d
    etc/environment.d

    usr/lib/systemd/system

    usr/lib/sane
    usr/lib64/sane

    usr/lib/cups
    usr/lib64/cups

    usr/lib/cups/backend
    usr/lib64/cups/backend

    usr/share/cups/model
    usr/share/cups/drv
    usr/share/epson
    usr/share/imagescan
    usr/share/applications

    usr/libexec

    usr/local
    usr/local/share
    usr/local/lib

    var/lib
)

TAR_OPTS=()
_tar_probe="/etc/os-release"
if [[ ! -e "$_tar_probe" ]]; then
    _tar_probe="/etc/hostname"
fi

if [[ -e "$_tar_probe" ]] && tar --selinux --acls --xattrs -cf /dev/null "$_tar_probe" >/dev/null 2>&1; then
    TAR_OPTS+=(--selinux --acls --xattrs)
fi

APT_LOCAL=()
APT_LOCAL_ENABLED=0
LOCAL_SOURCES=""
LOCAL_SOURCEPARTS=""
CLEANUP_TMPDIRS=()

APT_NET_OPTS=(
    -o "Acquire::Retries=1"
    -o "Acquire::http::Timeout=15"
    -o "Acquire::https::Timeout=15"
    -o "Acquire::ftp::Timeout=15"
)

if [[ "${ALT_SYNC_APT_INTERACTIVE:-0}" != "1" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    APT_NO_PROMPT_OPTS=(
        -o "APT::Get::Assume-Yes=true"
        -o "APT::Get::Show-Versions=false"
        -o "Dpkg::Options::=--force-confdef"
        -o "Dpkg::Options::=--force-confold"
    )
else
    APT_NO_PROMPT_OPTS=()
fi

install_pkg_by_name() {
    local pkg="$1"
    if have_cmd apt-get; then
        env DEBIAN_FRONTEND=noninteractive apt-get "${APT_NET_OPTS[@]}" \
            "${APT_NO_PROMPT_OPTS[@]}" install -y "$pkg" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 && return 0
    fi
    if have_cmd epm; then
        epm --no-prompt install "$pkg" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 && return 0
    fi
    return 1
}

REPO_INDEX_REFRESHED=0
refresh_repo_indexes_once() {
    (( REPO_INDEX_REFRESHED == 1 )) && return 0
    REPO_INDEX_REFRESHED=1
    if [[ "${ALT_SYNC_ALLOW_NET:-0}" != "1" ]]; then
        log "INFO: Сеть для установки зависимостей не разрешена (ALT_SYNC_ALLOW_NET!=1) — пропускаю обновление индексов."
        return 0
    fi
    if have_cmd apt-get; then
        env DEBIAN_FRONTEND=noninteractive apt-get "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" update </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || \
            log "WARN: apt-get update завершился с ошибкой (продолжаю с текущими индексами)."
    elif have_cmd epm; then
        epm --no-prompt refresh </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || \
            log "WARN: epm refresh завершился с ошибкой (продолжаю с текущими индексами)."
    fi
}

ensure_packages_present() {
    local -a pkgs=("$@")
    local missing=() p fail=0
    ((${#pkgs[@]} == 0)) && return 0
    for p in "${pkgs[@]}"; do
        have_cmd "$p" || missing+=("$(pkg_for_cmd "$p")")
    done
    ((${#missing[@]} == 0)) && return 0
    if ! have_cmd apt-get && ! have_cmd epm; then
        step_warn "Нет apt-get/epm — не могу установить: ${missing[*]}"
        return 1
    fi
    info "Устанавливаю недостающие пакеты: ${missing[*]}"
    refresh_repo_indexes_once
    for p in "${missing[@]}"; do
        if install_pkg_by_name "$p"; then
            log "INFO: пакет $p установлен."
        else
            warn "Не удалось установить пакет: $p"
            fail=1
        fi
    done
    return "$fail"
}

auto_install_dependencies() {
    local -a need_pkgs=()
    local spec c p
    local -A opt_pkgs=([dialog]=1 [libnotify]=1 [qarma]=1 [yad]=1 [zenity]=1 [kdialog]=1)
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        if ! have_cmd "$c"; then
            [[ "${ALT_SYNC_GUI:-0}" == "1" && -n "${opt_pkgs[$p]:-}" ]] && continue
            need_pkgs+=("$p")
        fi
    done
    ((${#need_pkgs[@]} == 0)) && { log "INFO: Все зависимости на месте."; return 0; }
    local -A seen=(); local -a uniq=()
    for p in "${need_pkgs[@]}"; do
        [[ -n "${seen[$p]:-}" ]] && continue
        seen["$p"]=1; uniq+=("$p")
    done
    info "Не хватает зависимостей (${#uniq[@]}): ${uniq[*]}. Пробую установить автоматически..."
    set +e
    local -a still_missing=()
    if deps_cache_available; then
        info "Пробую установить недостающие зависимости из офлайн-кэша: $DEPS_CACHE_DIR"
        install_pkgs_from_offline_cache "${uniq[@]}" || true
        for p in "${uniq[@]}"; do
            have_cmd "$(pkg_for_cmd_reverse "$p")" || still_missing+=("$p")
        done
    else
        still_missing=("${uniq[@]}")
    fi
    if ((${#still_missing[@]} > 0)); then
        refresh_repo_indexes_once
        local ok=0 fail=0
        for p in "${still_missing[@]}"; do
            if install_pkg_by_name "$p"; then
                ok=$((ok+1)); log "INFO: установлен пакет $p."
            else
                fail=$((fail+1)); warn "Не удалось установить пакет: $p"
            fi
        done
        log "INFO: автоустановка зависимостей из сети: успех=$ok, ошибок=$fail."
    fi
    set -e
}

pkg_for_cmd_reverse() {
    local want="$1" spec c p
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        [[ "$p" == "$want" ]] && { printf '%s' "$c"; return 0; }
    done
    printf '%s' "$want"
}

cleanup_local_apt() {
    if [[ -n "${LOCAL_SOURCES:-}" ]]; then
        rm -f "$LOCAL_SOURCES" 2>/dev/null || true
    fi
    if [[ -n "${LOCAL_SOURCEPARTS:-}" ]]; then
        rm -rf "$LOCAL_SOURCEPARTS" 2>/dev/null || true
    fi
    LOCAL_SOURCES=""
    LOCAL_SOURCEPARTS=""
    APT_LOCAL=()
    APT_LOCAL_ENABLED=0
}

DEPS_CACHE_DIR="${ALT_SYNC_DEPS_CACHE_DIR:-${SCRIPT_DIR}/deps-rpm}"
DEPS_MANIFEST="$DEPS_CACHE_DIR/deps.manifest"

deps_cache_available() {
    [[ -d "$DEPS_CACHE_DIR" ]] && \
        find "$DEPS_CACHE_DIR" -maxdepth 1 \( -name '*.rpm' -o -name '*.deb' \) -print -quit 2>/dev/null | grep -q .
}

apt_local_deb_source() {
    printf 'deb [trusted=yes] file:%s ./\n' "$DEPS_CACHE_DIR"
}

refresh_local_index() {
    local src_list sparts rc fmt_line="$1"
    if [[ -n "${2:-}" ]]; then fmt_line="$2"; fi
    src_list="$(mktemp "${TMPDIR:-/tmp}/alt-sync-depsrc.XXXXXX")" || return 1
    sparts="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-depsparts.XXXXXX")" || { rm -f "$src_list"; return 1; }
    printf '%s\n' "$fmt_line" > "$src_list"
    if command -v timeout >/dev/null 2>&1; then
        env DEBIAN_FRONTEND=noninteractive timeout 60 apt-get \
            -o "Dir::Etc::sourcelist=$src_list" \
            -o "Dir::Etc::sourceparts=$sparts" \
            -o "Acquire::AllowInsecureRepositories=true" \
            update -qq </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1
        rc=$?
    else
        env DEBIAN_FRONTEND=noninteractive apt-get \
            -o "Dir::Etc::sourcelist=$src_list" \
            -o "Dir::Etc::sourceparts=$sparts" \
            -o "Acquire::AllowInsecureRepositories=true" \
            update -qq </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1
        rc=$?
    fi
    rm -f "$src_list"; rm -rf "$sparts"
    return "$rc"
}

install_pkgs_from_offline_cache() {
    local -a pkgs=("$@")
    ((${#pkgs[@]} == 0)) && return 0
    deps_cache_available || return 1

    local _saved_sources="$LOCAL_SOURCES" _saved_parts="$LOCAL_SOURCEPARTS"
    local _saved_local=("${APT_LOCAL[@]}") _saved_enabled="$APT_LOCAL_ENABLED"

    LOCAL_SOURCES="$(mktemp "${TMPDIR:-/tmp}/alt-sync-offline-src.XXXXXX.list")"
    LOCAL_SOURCEPARTS="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-offline-parts.XXXXXX")"
    mkdir -p "$LOCAL_SOURCEPARTS"
    local have_rpm=0 have_deb=0
    find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.rpm' -print -quit 2>/dev/null | grep -q . && have_rpm=1
    find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null | grep -q . && have_deb=1
    {
        (( have_rpm )) && printf 'rpm dir:%s\n' "$DEPS_CACHE_DIR"
        (( have_deb )) && apt_local_deb_source
    } > "$LOCAL_SOURCES"
    APT_LOCAL=(
        -o "Dir::Etc::sourcelist=$LOCAL_SOURCES"
        -o "Dir::Etc::sourceparts=$LOCAL_SOURCEPARTS"
        -o "Acquire::AllowInsecureRepositories=true"
    )
    APT_LOCAL_ENABLED=0
    local _idx_line
    if (( have_deb )); then _idx_line="$(apt_local_deb_source)"; else _idx_line="rpm dir:$DEPS_CACHE_DIR"; fi
    refresh_local_index "$DEPS_CACHE_DIR" "$_idx_line" && APT_LOCAL_ENABLED=1

    local p c still_missing=()
    for p in "${pkgs[@]}"; do
        if (( APT_LOCAL_ENABLED == 1 )) && apt_install_local "$p"; then
            log "INFO: пакет $p установлен из офлайн-кэша ($DEPS_CACHE_DIR)."
            continue
        fi
        if (( have_rpm )) && have_cmd rpm; then
            rpm -Uhv --replacepkgs --nodeps "$DEPS_CACHE_DIR"/*.rpm </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        fi
        if (( have_deb )); then
            c="$(pkg_for_cmd_reverse "$p")"
            if ! have_cmd "$c" && command -v dpkg >/dev/null 2>&1; then
                local debf
                for debf in "$DEPS_CACHE_DIR"/"$p"_*.deb "$DEPS_CACHE_DIR"/"$p"-*.deb "$DEPS_CACHE_DIR"/"$p".deb; do
                    [[ -f "$debf" ]] || continue
                    env DEBIAN_FRONTEND=noninteractive dpkg -i --force-depends "$debf" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
                done
            fi
        fi
        c="$(pkg_for_cmd_reverse "$p")"
        if have_cmd "$c"; then
            log "INFO: пакет $p получен из офлайн-кэша."
            continue
        fi
        still_missing+=("$p")
    done

    rm -f "$LOCAL_SOURCES"; rm -rf "$LOCAL_SOURCEPARTS"
    LOCAL_SOURCES="$_saved_sources"; LOCAL_SOURCEPARTS="$_saved_parts"
    APT_LOCAL=("${_saved_local[@]}"); APT_LOCAL_ENABLED="$_saved_enabled"
    ((${#still_missing[@]} == 0)) && return 0
    return 1
}

fetch_deps_cache() {
    if ! have_cmd apt-get; then
        die "Для скачивания нужен apt-get (пакет apt)."
    fi
    mkdir -p "$DEPS_CACHE_DIR" || die "Не могу создать каталог кэша: $DEPS_CACHE_DIR"

    info "Скачиваю зависимости скрипта в офлайн-кэш: $DEPS_CACHE_DIR"
    ALT_SYNC_ALLOW_NET=1; export ALT_SYNC_ALLOW_NET
    OPT_NETWORK_ENABLED=1
    refresh_repo_indexes_once

    local -A seen=(); local -a pkgs=() spec c p
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        [[ -n "${seen[$p]:-}" ]] && continue
        seen["$p"]=1; pkgs+=("$p")
    done

    local tmp total=${#pkgs[@]} done_n=0 failed=() notavail=()
    if have_cmd apt-get; then
        local _pol
        for ((i = total - 1; i >= 0; i--)); do
            _pol=$(apt-cache policy "${pkgs[$i]}" 2>/dev/null | grep -cE '^\s+[0-9]+:') || _pol=0
            if (( _pol == 0 )); then
                notavail+=("${pkgs[$i]}")
                unset 'pkgs[i]'
                pkgs=("${pkgs[@]}")
            fi
        done
    elif have_cmd epm; then
        local _e
        for ((i = total - 1; i >= 0; i--)); do
            if ! epm --no-prompt query "${pkgs[$i]}" >/dev/null 2>&1; then
                notavail+=("${pkgs[$i]}")
                unset 'pkgs[i]'
                pkgs=("${pkgs[@]}")
            fi
        done
    fi
    ((${#notavail[@]} > 0)) && log "INFO: пропущены недоступные в репозиториях пакеты: ${notavail[*]}"
    total=${#pkgs[@]}
    if (( total == 0 )); then
        step_warn "Все проверяемые пакеты уже установлены или недоступны — скачивать нечего."
        return 0
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-fetch.XXXXXX")" || die "mktemp не удался"
    add_cleanup_tmpdir "$tmp"

    local batch=()
    local i
    for ((i = 0; i < total; i++)); do
        batch+=("${pkgs[$i]}")
        done_n=$((done_n + 1))
        progress_bar "$done_n" "$total" "Скачивание зависимостей"
        if (( ${#batch[@]} >= 20 )) || (( done_n == total )); then
            (
                cd "$tmp" || exit 1
                apt_with_timeout 300 "${APT_NET_OPTS[@]}" download "${batch[@]}" </dev/null >>"$LOG_FILE" 2>&1
            ) || failed+=("${batch[*]}")
            batch=()
        fi
    done

    local f copied=0
    while IFS= read -r -d '' f; do
        safe_copy "$f" "$DEPS_CACHE_DIR" && copied=$((copied + 1))
    done < <(find "$tmp" -maxdepth 1 -type f \( -name '*.rpm' -o -name '*.deb' \) -print0 2>/dev/null)

    if find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null | grep -q .; then
        if command -v dpkg-scanpackages >/dev/null 2>&1; then
            ( cd "$DEPS_CACHE_DIR" && dpkg-scanpackages --multiversion . 2>>"$LOG_FILE" | gzip -9c > Packages.gz ) \
                && log "INFO: индекс DEB-кэша собран: $DEPS_CACHE_DIR/Packages.gz" \
                || warn "dpkg-scanpackages не смог собрать индекс DEB-кэша (установка дебов пойдёт через dpkg -i)."
        else
            info "dpkg-scanpackages отсутствует — офлайн-установка DEB будет прямой (dpkg -i)."
        fi
    fi

    {
        printf '# alt_sync offline deps cache manifest\n'
        printf '# generated: %s\n' "$(date -Is)"
        printf '# host: %s\n' "$(hostname)"
        ( cd "$DEPS_CACHE_DIR" && sha256sum ./*.rpm ./*.deb 2>/dev/null )
    } > "$DEPS_MANIFEST" 2>/dev/null || true

    rm -rf "$tmp"
    if (( copied == 0 )); then
        step_warn "Не удалось скачать ни одного пакета — проверьте интернет и репозитории."
        return 1
    fi
    if ((${#failed[@]} > 0)); then
        step_warn "Часть пакетов не скачалась: ${failed[*]} (см. техлог)."
    fi
    step_ok "Офлайн-кэш готов: $DEPS_CACHE_DIR ($copied пакетов, $(du -sh "$DEPS_CACHE_DIR" 2>/dev/null | cut -f1))."
    info "Перенесите весь каталог скрипта (включая deps-rpm/) на компьютеры без интернета — зависимости установятся автономно."
    return 0
}

add_cleanup_tmpdir() {
    CLEANUP_TMPDIRS+=("$1")
}

cleanup_all() {
    cleanup_local_apt
    local d
    for d in ${CLEANUP_TMPDIRS[@]+"${CLEANUP_TMPDIRS[@]}"}; do
        rm -rf "$d" 2>/dev/null || true
    done
}

trap cleanup_all EXIT INT TERM

generate_machine_id() {
    local -a parts=()

    if [[ -r /etc/machine-id ]]; then
        parts+=("$(< /etc/machine-id)")
    fi

    if [[ -r /var/lib/dbus/machine-id ]]; then
        parts+=("$(< /var/lib/dbus/machine-id)")
    fi

    if [[ -r /sys/class/dmi/id/product_uuid ]]; then
        parts+=("$(< /sys/class/dmi/id/product_uuid)")
    fi

    if [[ -r /sys/class/dmi/id/board_serial ]]; then
        parts+=("$(< /sys/class/dmi/id/board_serial)")
    fi

    parts+=("$(uname -m)")

    printf '%s\n' "${parts[@]}" | sha256sum | cut -d' ' -f1
}

check_machine_match() {
    local current_id stored_id
    current_id="$(generate_machine_id)"

    if [[ ! -f "$MACHINE_ID_FILE" ]]; then
        mkdir -p "$BACKUP_DIR"
        printf '%s\n' "$current_id" > "$MACHINE_ID_FILE"
        info "Маркер эталонной машины создан."
        return 0
    fi

    if [[ ! -r "$MACHINE_ID_FILE" ]]; then
        step_fail "Маркер эталона существует, но не читается: $MACHINE_ID_FILE"
        return 1
    fi

    stored_id="$(tr -d '\r\n ' < "$MACHINE_ID_FILE" 2>/dev/null || true)"

    if [[ "$current_id" == "$stored_id" ]]; then
        return 0
    fi

    step_warn "Текущая машина не совпадает с маркером эталона."
    if ask_yes_no "Всё равно экспортировать с этой машины?" n; then
        info "Экспорт разрешён вручную через меню."
        return 0
    fi

    step_fail "Экспорт отменён: это не эталонная машина."
    return 1
}

append_existing_rel_to_list() {
    local list="$1"
    local rel="${2#/}"

    if [[ -n "$rel" && -e "/$rel" ]]; then
        printf '%s\0' "$rel" >> "$list"
    fi
}

tar_create_to_file() {
    local out="$1"
    shift

    rm -f "$out" 2>/dev/null || true

    local rc=0
    tar ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} "$@" -f "$out" 2>>"$LOG_FILE" || rc=$?

    (( rc <= 1 ))
}

tar_extract_preserve() {
    local archive="$1"
    local base="$2"

    local rc=0
    tar ${TAR_OPTS[@]+"${TAR_OPTS[@]}"} -C "$base" -xf "$archive" 2>>"$LOG_FILE" || rc=$?

    (( rc <= 1 ))
}

tar_extract_safe() {
    local archive="$1"
    local base="$2"
    local rc=0

    tar --no-same-owner --no-permissions --no-xattrs --no-acls --no-selinux \
        -C "$base" -xf "$archive" 2>>"$LOG_FILE" || rc=$?
    if (( rc <= 1 )); then
        return 0
    fi

    tar --no-same-owner -C "$base" -xf "$archive" 2>>"$LOG_FILE" || rc=$?
    if (( rc <= 1 )); then
        return 0
    fi

    tar -C "$base" -xf "$archive" 2>>"$LOG_FILE" || rc=$?

    (( rc <= 1 ))
}

safe_copy() {
    local src="$1"
    local dst_dir="$2"

    local name dest tmp

    name="$(basename -- "$src")"
    dest="$dst_dir/$name"
    tmp="$dest.tmp.$$"

    rm -f "$tmp" 2>/dev/null || true

    if cp --no-preserve=all -- "$src" "$tmp" 2>>"$LOG_FILE"; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv -f -- "$tmp" "$dest" 2>>"$LOG_FILE"; then
            return 0
        fi
    fi

    rm -f "$tmp" 2>/dev/null || true

    if cat -- "$src" > "$tmp" 2>>"$LOG_FILE"; then
        chmod 0644 "$tmp" 2>/dev/null || true
        if mv -f -- "$tmp" "$dest" 2>>"$LOG_FILE"; then
            return 0
        fi
    fi

    rm -f "$tmp" 2>/dev/null || true
    return 1
}

RPM_INDEX_FILE=""
declare -A RPM_BY_NVRA=()
declare -A RPM_BY_SPEC=()
declare -A RPM_BY_NAME=()

resolve_rpm_index_file() {
    if [[ -n "${RPM_INDEX_FILE:-}" ]]; then
        return 0
    fi
    RPM_INDEX_FILE="$LISTS_DIR/rpm-index.tsv"
}

build_rpm_file_index() {
    resolve_rpm_index_file
    mkdir -p "$LISTS_DIR"

    : > "$RPM_INDEX_FILE" 2>>"$LOG_FILE" || {
        step_warn "Не удалось создать индекс RPM: $RPM_INDEX_FILE"
        return 1
    }

    if [[ ! -d "$PACKAGES_DIR" ]]; then
        return 0
    fi

    local total cur=0 f
    total="$(find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.rpm' 2>/dev/null | wc -l)"

    progress_reset

    local name epoch ver rel arch nvra spec fname

    while IFS= read -r -d '' f; do
        cur=$((cur + 1))
        progress_bar "$cur" "$total" "Индексация RPM" "$(basename -- "$f")"

        if ! IFS='|' read -r name epoch ver rel arch < <(
            rpm -qp --qf '%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\n' "$f" 2>/dev/null
        ); then
            continue
        fi

        if [[ -z "$name" || -z "$ver" || -z "$rel" || -z "$arch" ]]; then
            continue
        fi

        if [[ "$epoch" == "(none)" ]]; then
            epoch=""
        fi

        nvra="$name-$ver-$rel.$arch"

        if [[ -n "$epoch" ]]; then
            spec="$name=$epoch:$ver-$rel.$arch"
        else
            spec="$name=$ver-$rel.$arch"
        fi

        fname="$(basename -- "$f")"

        if ! printf '%s\t%s\t%s\t%s\n' "$name" "$nvra" "$spec" "$fname" >> "$RPM_INDEX_FILE"; then
            step_warn "Не удалось записать индекс RPM для: $f"
            return 1
        fi
    done < <(find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.rpm' -print0 2>/dev/null)

    if (( total > 0 && cur >= total )); then
        printf '\n'
    fi

    return 0
}

load_rpm_index() {
    resolve_rpm_index_file

    RPM_BY_NVRA=()
    RPM_BY_SPEC=()
    RPM_BY_NAME=()

    [[ -r "$RPM_INDEX_FILE" ]] || return 0

    local name nvra spec filename path

    while IFS=$'\t' read -r name nvra spec filename; do
        if [[ -z "$nvra" || -z "$filename" ]]; then
            continue
        fi

        path="$PACKAGES_DIR/$filename"
        if [[ ! -f "$path" ]]; then
            continue
        fi

        RPM_BY_NVRA["$nvra"]="$path"
        if [[ -n "$spec" ]]; then
            RPM_BY_SPEC["$spec"]="$path"
        fi

        if [[ -n "$name" ]]; then
            if [[ -n "${RPM_BY_NAME[$name]:-}" ]]; then
                RPM_BY_NAME["$name"]+=$'\n'"$path"
            else
                RPM_BY_NAME["$name"]="$path"
            fi
        fi
    done < "$RPM_INDEX_FILE"
}

ensure_rpm_index() {
    resolve_rpm_index_file

    if [[ ! -s "$RPM_INDEX_FILE" && -d "$PACKAGES_DIR" ]]; then
        build_rpm_file_index || true
    fi

    load_rpm_index
}

spec_to_nvra() {
    local spec="$1"
    local name rest

    name="${spec%%=*}"
    rest="${spec#*=}"
    rest="${rest#*:}"

    printf '%s-%s\n' "$name" "$rest"
}

update_system_lists_if_needed() {
    if (( OPT_NETWORK_ENABLED != 1 )); then
        return 0
    fi

    if (( SYSTEM_LISTS_UPDATED == 1 )); then
        return 0
    fi

    info "Обновляю системные списки APT..."
    if command -v timeout >/dev/null 2>&1; then
        env DEBIAN_FRONTEND=noninteractive timeout 30 apt-get "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" update -qq </dev/null >>"$LOG_FILE" 2>&1 || true
    else
        env DEBIAN_FRONTEND=noninteractive apt-get "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" update -qq </dev/null >>"$LOG_FILE" 2>&1 || true
    fi

    SYSTEM_LISTS_UPDATED=1
}

apt_with_timeout() {
    local seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" apt-get "$@" </dev/null
    else
        apt-get "$@" </dev/null
    fi
}

apt_install_local() {
    if (( $# == 0 )); then
        return 1
    fi

    if (( APT_LOCAL_ENABLED != 1 )) || (( ${#APT_LOCAL[@]} == 0 )); then
        return 1
    fi

    apt_with_timeout 120 "${APT_LOCAL[@]}" "${APT_NO_PROMPT_OPTS[@]}" install -y "$@" </dev/null >>"$LOG_FILE" 2>&1
}

apt_install_system() {
    if (( $# == 0 )); then
        return 1
    fi

    if (( OPT_NETWORK_ENABLED != 1 )); then
        return 1
    fi

    update_system_lists_if_needed
    apt_with_timeout 120 "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" install -y "$@" </dev/null >>"$LOG_FILE" 2>&1
}

apt_install_pkg() {
    if (( $# == 0 )); then
        return 1
    fi

    apt_install_local "$@" || apt_install_system "$@"
}

install_rpm_file() {
    local rpm_file="$1"

    if [[ ! -f "$rpm_file" ]]; then
        return 1
    fi

    log "Установка RPM-файла: $rpm_file"

    if apt_install_pkg "$rpm_file"; then
        return 0
    fi

    if rpm -Uvh --replacepkgs --oldpackage "$rpm_file" </dev/null >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    if (( OPT_ALLOW_NODEPS == 1 )); then
        if rpm -Uvh --nodeps --replacepkgs --oldpackage "$rpm_file" </dev/null >>"$LOG_FILE" 2>&1; then
            log "RPM установлен с --nodeps по явному разрешению: $rpm_file"
            return 0
        fi
    fi

    return 1
}

install_rpm_files_group() {
    if (( $# == 0 )); then
        return 1
    fi

    local -a files=("$@")
    local -a rpm_paths=() spec_names=()
    local item
    for item in "${files[@]}"; do
        if [[ "$item" == *.rpm ]]; then
            rpm_paths+=("$item")
        else
            spec_names+=("$item")
        fi
    done

    log "Групповая установка RPM: ${#files[@]} позиц. (файлов: ${#rpm_paths[@]}, спецификаций: ${#spec_names[@]})"

    if (( ${#rpm_paths[@]} > 0 )); then
        if apt_install_pkg "${rpm_paths[@]}"; then
            return 0
        fi
        if rpm -Uvh --replacepkgs --oldpackage "${rpm_paths[@]}" </dev/null >>"$LOG_FILE" 2>&1; then
            return 0
        fi
        if (( OPT_ALLOW_NODEPS == 1 )); then
            if rpm -Uvh --nodeps --replacepkgs --oldpackage "${rpm_paths[@]}" </dev/null >>"$LOG_FILE" 2>&1; then
                log "Группа RPM установлена с --nodeps по явному разрешению"
                return 0
            fi
        fi
    fi

    local rc=1
    if (( ${#spec_names[@]} > 0 )); then
        local spec
        for spec in "${spec_names[@]}"; do
            if install_spec "$spec"; then
                rc=0
            fi
        done
    fi

    return "$rc"
}

install_package_name() {
    local pkg="$1"

    [[ -n "$pkg" ]] || return 1

    if rpm -q "$pkg" >/dev/null 2>&1; then
        return 0
    fi

    log "Установка пакета по имени: $pkg"

    local path
    if [[ -n "${RPM_BY_NAME[$pkg]:-}" ]]; then
        while IFS= read -r path; do
            if [[ -f "$path" ]]; then
                if install_rpm_file "$path"; then
                    return 0
                fi
            fi
        done <<< "${RPM_BY_NAME[$pkg]}"
    fi

    if apt_install_pkg "$pkg"; then
        return 0
    fi

    return 1
}

install_spec() {
    local spec="$1"
    local nvra

    [[ -n "$spec" ]] || return 1

    nvra="$(spec_to_nvra "$spec")"

    if rpm -q "$nvra" >/dev/null 2>&1; then
        return 0
    fi

    log "Установка по spec: $spec"

    if apt_install_local "$spec"; then
        return 0
    fi

    if [[ -n "${RPM_BY_SPEC[$spec]:-}" ]]; then
        if install_rpm_file "${RPM_BY_SPEC[$spec]}"; then
            return 0
        fi
    fi

    if [[ -n "${RPM_BY_NVRA[$nvra]:-}" ]]; then
        if install_rpm_file "${RPM_BY_NVRA[$nvra]}"; then
            return 0
        fi
    fi

    if apt_install_system "$spec"; then
        return 0
    fi

    return 1
}

install_local_rpm_directory_fallback() {
    if [[ ! -d "$PACKAGES_DIR" ]]; then
        return 0
    fi

    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/alt-sync-local-rpms.XXXXXX")" || return 0

    find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.rpm' -print0 > "$tmp" 2>>"$LOG_FILE" || {
        rm -f "$tmp"
        return 0
    }

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 0
    fi

    info "Пробую массово установить RPM из packages/ через rpm..."

    xargs -0 -r -n 100 rpm -Uvh --replacepkgs --oldpackage < "$tmp" </dev/null >>"$LOG_FILE" 2>&1 || true

    if (( OPT_ALLOW_NODEPS == 1 )); then
        info "Повторная установка RPM с --nodeps разрешена меню."
        xargs -0 -r -n 100 rpm -Uvh --nodeps --replacepkgs --oldpackage < "$tmp" </dev/null >>"$LOG_FILE" 2>&1 || true
    fi

    rm -f "$tmp"
    return 0
}

write_manifest() {
    local os_pretty="unknown"
    if [[ -r /etc/os-release ]]; then
        os_pretty="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
    fi

    local tar_opts_str="${TAR_OPTS[*]-}"
    tar_opts_str="${tar_opts_str:-none}"

    cat > "$BACKUP_DIR/MANIFEST" <<EOF
script_version=$SCRIPT_VERSION
created=$(date -Is)
hostname=$(hostname)
arch=$(uname -m)
kernel=$(uname -r)
os=$os_pretty
target_user=${TARGET_USER:-}
home_dir=${HOME_DIR:-}
backup_dir=$BACKUP_DIR
log_dir=$LOG_DIR
tar_opts=$tar_opts_str
EOF
}

save_package_manifest() {
    mkdir -p "$LISTS_DIR"

    local fields="$LISTS_DIR/installed_fields.txt"
    local nvra_file="$LISTS_DIR/installed_nvra.txt"
    local spec_file="$LISTS_DIR/installed_specs.txt"
    local special_file="$LISTS_DIR/special_packages.txt"

    rpm -qa --qf '%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\n' |
        sort -u > "$fields"

    : > "$nvra_file"
    : > "$spec_file"

    awk -F'|' -v nf="$nvra_file" -v sf="$spec_file" '
    {
        name=$1
        epoch=$2
        ver=$3
        rel=$4
        arch=$5

        nvra = name "-" ver "-" rel "." arch
        print nvra > nf

        spec = name "="
        if (epoch != "(none)" && epoch != "") {
            spec = spec epoch ":"
        }
        spec = spec ver "-" rel "." arch
        print spec > sf
    }' "$fields"

    : > "$special_file"

    local pkg
    for pkg in "${EPSON_PKGS[@]}" "${PANTUM_PKGS[@]}" "${CRYPTO_PKGS[@]}"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >> "$special_file"
        fi
    done
}

copy_all_rpm_sources() {
    mkdir -p "$PACKAGES_DIR"

    local -a dirs=()
    [[ -d "$CACHE_DIR" ]] && dirs+=("$CACHE_DIR")
    [[ -d "$INSTALL_DIR" ]] && dirs+=("$INSTALL_DIR")

    if [[ -d "$BACKUP_DIR/install" && "$BACKUP_DIR/install" != "$INSTALL_DIR" ]]; then
        dirs+=("$BACKUP_DIR/install")
    fi

    if (( ${#dirs[@]} == 0 )); then
        return 0
    fi

    local total=0 d cnt
    for d in "${dirs[@]}"; do
        if [[ "$d" == "$CACHE_DIR" ]]; then
            cnt="$(find "$d" -maxdepth 1 -type f -name '*.rpm' 2>/dev/null | wc -l)"
        else
            cnt="$(find "$d" -type f -name '*.rpm' 2>/dev/null | wc -l)"
        fi
        total=$((total + cnt))
    done

    progress_reset

    local cur=0 copied=0 failed=0 f

    for d in "${dirs[@]}"; do
        if [[ "$d" == "$CACHE_DIR" ]]; then
            while IFS= read -r -d '' f; do
                cur=$((cur + 1))
                if safe_copy "$f" "$PACKAGES_DIR"; then
                    copied=$((copied + 1))
                else
                    failed=$((failed + 1))
                    log "Не скопирован RPM: $f"
                fi
                progress_bar "$cur" "$total" "Копирование RPM" "$(basename -- "$f")"
            done < <(find "$d" -maxdepth 1 -type f -name '*.rpm' -print0 2>/dev/null)
        else
            while IFS= read -r -d '' f; do
                cur=$((cur + 1))
                if safe_copy "$f" "$PACKAGES_DIR"; then
                    copied=$((copied + 1))
                else
                    failed=$((failed + 1))
                    log "Не скопирован RPM: $f"
                fi
                progress_bar "$cur" "$total" "Копирование RPM" "$(basename -- "$f")"
            done < <(find "$d" -type f -name '*.rpm' -print0 2>/dev/null)
        fi
    done

    if (( total > 0 && cur >= total )); then
        printf '\n'
    fi

    log "Скопировано RPM: $copied, ошибок: $failed"

    if (( failed > 0 )); then
        step_warn "Не удалось скопировать $failed RPM-файл(ов). Подробности в логе."
    fi
}

find_missing_nvra() {
    local out="$1"
    : > "$out"

    [[ -f "$LISTS_DIR/installed_nvra.txt" ]] || return 0

    local nvra
    while IFS= read -r nvra; do
        if [[ -z "$nvra" ]]; then
            continue
        fi
        if [[ -z "${RPM_BY_NVRA[$nvra]:-}" ]]; then
            echo "$nvra" >> "$out"
        fi
    done < "$LISTS_DIR/installed_nvra.txt"
}

find_missing_specs() {
    local out="$1"
    : > "$out"

    [[ -f "$LISTS_DIR/installed_specs.txt" ]] || return 0

    local spec nvra
    while IFS= read -r spec; do
        if [[ -z "$spec" ]]; then
            continue
        fi

        nvra="$(spec_to_nvra "$spec")"

        if [[ -z "${RPM_BY_SPEC[$spec]:-}" && -z "${RPM_BY_NVRA[$nvra]:-}" ]]; then
            echo "$spec" >> "$out"
        fi
    done < "$LISTS_DIR/installed_specs.txt"
}

apt_network_ok() {
    if (( OPT_NETWORK_ENABLED != 1 )); then
        return 1
    fi

    update_system_lists_if_needed
    return 0
}

download_batch() {
    if (( $# == 0 )); then
        return 0
    fi

    if ! apt_network_ok; then
        return 1
    fi

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-download.XXXXXX")" || return 1
    add_cleanup_tmpdir "$tmp"

    if (
        cd "$tmp" || exit 1
        apt_with_timeout 180 "${APT_NET_OPTS[@]}" download "$@" </dev/null >>"$LOG_FILE" 2>&1
    ); then
        local f
        while IFS= read -r -d '' f; do
            if ! safe_copy "$f" "$PACKAGES_DIR"; then
                log "Не удалось сохранить скачанный RPM: $f"
            fi
        done < <(find "$tmp" -maxdepth 1 -type f -name '*.rpm' -print0 2>/dev/null)
        return 0
    fi

    return 1
}

download_missing_specs() {
    local missing_specs="$1"

    [[ -s "$missing_specs" ]] || return 0

    if (( OPT_NETWORK_ENABLED != 1 )); then
        step_warn "Докачка отсутствующих RPM пропущена: интернет отключён в меню."
        return 0
    fi

    local total processed=0 failed=0
    total="$(wc -l < "$missing_specs")"

    info "Пробую докачать отсутствующие RPM: $total шт. Это может занять время."

    local -a batch=()
    local spec

    progress_reset

    while IFS= read -r spec; do
        if [[ -z "$spec" ]]; then
            continue
        fi

        batch+=("$spec")
        processed=$((processed + 1))
        progress_bar "$processed" "$total" "Докачка RPM" "${spec%%=*}"

        if (( ${#batch[@]} >= 30 )); then
            if ! download_batch "${batch[@]}"; then
                failed=$((failed + 1))
            fi
            batch=()
        fi
    done < "$missing_specs"

    if (( ${#batch[@]} > 0 )); then
        if ! download_batch "${batch[@]}"; then
            failed=$((failed + 1))
        fi
    fi

    if (( total > 0 && processed >= total )); then
        printf '\n'
    fi

    if (( failed > 0 )); then
        step_warn "Некоторые батчи докачки завершились с ошибкой: $failed. Подробности в логе."
    fi
}

build_local_repo_index() {
    local count=0
    if [[ -d "$PACKAGES_DIR" ]]; then
        count="$(find "$PACKAGES_DIR" -maxdepth 1 -type f -name '*.rpm' 2>/dev/null | wc -l)"
    fi

    if (( count == 0 )); then
        return 0
    fi

    local cmd
    for cmd in apt-ftparchive apt-rpm-ftparchive; do
        if command -v "$cmd" >/dev/null 2>&1; then
            (
                cd "$PACKAGES_DIR" || exit 1
                "$cmd" packages . > Packages 2>>"$LOG_FILE" &&
                    { command -v gzip >/dev/null 2>&1 && gzip -kf Packages 2>>"$LOG_FILE" || true; }
                "$cmd" release . > Release 2>>"$LOG_FILE" || true
            ) && return 0
        fi
    done

    if command -v createrepo_c >/dev/null 2>&1; then
        if createrepo_c "$PACKAGES_DIR" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
    fi

    install_package_name apt-utils >/dev/null 2>&1 || true
    install_package_name createrepo-c >/dev/null 2>&1 || true
    install_package_name createrepo_c >/dev/null 2>&1 || true

    for cmd in apt-ftparchive apt-rpm-ftparchive; do
        if command -v "$cmd" >/dev/null 2>&1; then
            (
                cd "$PACKAGES_DIR" || exit 1
                "$cmd" packages . > Packages 2>>"$LOG_FILE" &&
                    { command -v gzip >/dev/null 2>&1 && gzip -kf Packages 2>>"$LOG_FILE" || true; }
                "$cmd" release . > Release 2>>"$LOG_FILE" || true
            ) && return 0
        fi
    done

    if command -v createrepo_c >/dev/null 2>&1; then
        if createrepo_c "$PACKAGES_DIR" >>"$LOG_FILE" 2>&1; then
            return 0
        fi
    fi

    step_warn "Не удалось сгенерировать индекс APT. Будет использована прямая установка RPM по локальному индексу."
    return 0
}

collect_rpms() {
    mkdir -p "$PACKAGES_DIR" "$LISTS_DIR"

    copy_all_rpm_sources
    build_rpm_file_index || true
    load_rpm_index

    local missing_nvra="$LISTS_DIR/missing_nvra.txt"
    find_missing_nvra "$missing_nvra"

    if [[ -s "$missing_nvra" ]] && (( OPT_NETWORK_ENABLED == 1 && OPT_DOWNLOAD_MISSING == 1 )); then
        local missing_specs="$LISTS_DIR/missing_specs.txt"
        find_missing_specs "$missing_specs"

        if [[ -s "$missing_specs" ]]; then
            download_missing_specs "$missing_specs"
            build_rpm_file_index || true
            load_rpm_index
            find_missing_nvra "$missing_nvra"
        fi
    elif [[ -s "$missing_nvra" ]] && (( OPT_NETWORK_ENABLED == 1 )); then
        info "Докачка недостающих RPM отключена в режиме экспорта — используются только локальные источники."
    fi

    if [[ -s "$missing_nvra" ]]; then
        step_warn "Не найдены локальные RPM для $(wc -l < "$missing_nvra") пакетов. Список: $missing_nvra"
        step_warn "При импорте эти пакеты будут искаться в репозиториях, если интернет разрешён в меню."
    fi

    build_local_repo_index
    return 0
}

backup_system_configs() {
    mkdir -p "$CONFIGS_DIR"

    local list
    list="$(mktemp "${TMPDIR:-/tmp}/alt-sync-system-list.XXXXXX")" || {
        step_warn "Не удалось создать временный список системных конфигов."
        return 0
    }

    : > "$list"

    local p
    for p in \
        etc/cups/printers.conf \
        etc/cups/ppd \
        etc/cups/cupsd.conf \
        etc/cups/cups-files.conf \
        etc/sane.d \
        etc/cryptopro \
        etc/opt/cprocsp \
        etc/pantum \
        etc/epson \
        etc/iscan \
        etc/imagescan \
        etc/fstab \
        etc/hostname \
        etc/timezone \
        etc/localtime \
        etc/hosts \
        etc/resolv.conf \
        etc/network/interfaces \
        etc/NetworkManager/system-connections \
        etc/systemd/network \
        etc/systemd/resolved.conf \
        etc/locale.conf \
        etc/vconsole.conf \
        etc/X11/xorg.conf \
        etc/X11/xorg.conf.d \
        etc/X11/xinit \
        etc/lightdm \
        etc/sddm.conf \
        etc/sddm.conf.d \
        etc/skel \
        etc/group \
        etc/gshadow \
        etc/passwd \
        etc/shadow \
        etc/ssh/sshd_config \
        etc/ssh/ssh_config \
        etc/ssh/ssh_config.d \
        etc/alternatives \
        etc/ld.so.conf \
        etc/ld.so.conf.d \
        etc/profile \
        etc/profile.d \
        etc/bashrc \
        etc/environment \
        etc/environment.d \
        etc/init.d \
        etc/rc.d \
        etc/rc.local \
        etc/crontab \
        etc/anacrontab \
        etc/cron.d \
        etc/cron.hourly \
        etc/cron.daily \
        etc/cron.weekly \
        etc/cron.monthly \
        etc/systemd/journald.conf \
        etc/systemd/logind.conf \
        etc/polkit-1 \
        etc/dbus-1/system.d \
        etc/PackageKit \
        etc/apparmor.d \
        etc/usb_modeswitch.conf \
        etc/PackageKit.conf
    do
        append_existing_rel_to_list "$list" "$p"
    done

    for p in \
        var/lib/PackageKit/transactions.db \
        var/cache/alt-installer \
        var/lib/alt-installer \
        var/backups
    do
        append_existing_rel_to_list "$list" "$p"
    done

    for p in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
        [[ -d "/$p" ]] || continue
        local uf base tgt reldir
        while IFS= read -r -d '' uf; do
            append_existing_rel_to_list "$list" "${uf#/}"
            base="${uf%/*}"
            append_existing_rel_to_list "$list" "${base#/}"
            if [[ -L "$uf" ]]; then
                tgt="$(readlink -- "$uf" 2>/dev/null || true)"
                case "$tgt" in
                    /*) append_existing_rel_to_list "$list" "${tgt#/}" ;;
                    *)  reldir="$base/$tgt"
                        while [[ "$reldir" == */..* ]]; do
                            reldir="${reldir%%/..*}${reldir#*/..}"
                            reldir="${reldir#/}"
                        done
                        append_existing_rel_to_list "$list" "${reldir#/}"
                        append_existing_rel_to_list "$list" "$(dirname "${reldir#/}")"
                        ;;
                esac
            fi
        done < <(find "/$p" \( -type f -o -type l \) -print0 2>/dev/null)
    done

    if [[ -d /etc/udev/rules.d ]]; then
        local f
        while IFS= read -r -d '' f; do
            case "${f,,}" in
                *epson*|*pantum*|*crypto*|*cprocsp*|*iscan*|*sane*)
                    append_existing_rel_to_list "$list" "${f#/}" ;;
                *)
                    if grep -q ':=' "$f" 2>/dev/null; then
                        append_existing_rel_to_list "$list" "${f#/}"
                    fi ;;
            esac
        done < <(find /etc/udev/rules.d -maxdepth 1 -type f -name '*.rules' -print0 2>/dev/null)
    fi

    for p in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
        [[ -d "/$p" ]] || continue
        local wdir entry tgt
        while IFS= read -r -d '' wdir; do
            append_existing_rel_to_list "$list" "${wdir#/}"
            while IFS= read -r -d '' entry; do
                append_existing_rel_to_list "$list" "${entry#/}"
                if [[ -L "$entry" ]]; then
                    tgt="$(readlink -f -- "$entry" 2>/dev/null || true)"
                    [[ -n "$tgt" ]] && append_existing_rel_to_list "$list" "${tgt#/}"
                fi
            done < <(find "$wdir" -mindepth 1 -print0 2>/dev/null)
        done < <(find "/$p" -maxdepth 1 -type d \( -name '*.wants' -o -name '*.requires' \) -print0 2>/dev/null)
    done

    if [[ "${OPT_BACKUP_NETWORK_KEYS:-0}" != "1" ]]; then
        local nmrel="etc/NetworkManager/system-connections"
        local tmpfilter
        tmpfilter="$(mktemp "${TMPDIR:-/tmp}/alt-sync-nmfilter.XXXXXX")" || true
        if [[ -n "$tmpfilter" ]]; then
            { tr '\0' '\n' < "$list" 2>/dev/null |
              grep -v "^${nmrel}\(/\|$\)" 2>/dev/null |
              tr '\n' '\0' > "$tmpfilter"; } || true
            if [[ -s "$tmpfilter" ]]; then
                mv -f "$tmpfilter" "$list"
            else
                : > "$list"
            fi
            rm -f "$tmpfilter"
        fi
    fi

    local d
    for d in /etc/modprobe.d /etc/modules-load.d; do
        if [[ -d "$d" ]]; then
            local f
            while IFS= read -r -d '' f; do
                append_existing_rel_to_list "$list" "${f#/}"
            done < <(
                find "$d" -maxdepth 1 -type f -print0 2>/dev/null
            )
        fi
    done

    if [[ ! -s "$list" ]]; then
        rm -f "$list"
        step_warn "Системные конфиги не найдены."
        return 0
    fi

    sort -z -u -o "$list" "$list" || true

    if tar_create_to_file "$CONFIGS_DIR/system.tar" -c -C / --null -T "$list" &&
       [[ -s "$CONFIGS_DIR/system.tar" ]]; then
        rm -f "$list"
        step_ok "Системные конфиги сохранены"
        return 0
    fi

    rm -f "$list"
    step_warn "Не все системные конфиги были сохранены. Подробности в логе."
    return 0
}

backup_user_configs() {
    if [[ -z "${TARGET_USER:-}" ]] || (( OPT_BACKUP_USER != 1 )); then
        info "Пользовательский профиль пропущен."
        step_ok "Пользовательские конфиги не требовались"
        return 0
    fi

    mkdir -p "$CONFIGS_DIR"

    local -a paths=()
    local r

    for r in \
        .config \
        .local/share \
        .local/lib \
        .bashrc \
        .profile \
        .cprocsp \
        .crypto-pro \
        .sane \
        .epson \
        .pantum
    do
        if [[ -e "$HOME_DIR/$r" ]]; then
            paths+=("$r")
        fi
    done

    if (( OPT_SKIP_MOZILLA != 1 )) && [[ -e "$HOME_DIR/.mozilla" ]]; then
        paths+=(".mozilla")
    fi

    if (( ${#paths[@]} == 0 )); then
        step_warn "Пользовательские конфиги не найдены."
        return 0
    fi

    local -a excludes=(
        --exclude='.cache'
        --exclude='*/.cache'
        --exclude='.local/share/Trash'
        --exclude='*/Trash'
        --exclude='*/Trash/*'
        --exclude='.local/share/thumbnails'
        --exclude='*/thumbnails'
        --exclude='*/thumbnails/*'
        --exclude='*/cache'
        --exclude='*/Cache'
    )

    if tar_create_to_file "$CONFIGS_DIR/user.tar" -c ${excludes[@]+"${excludes[@]}"} -C "$HOME_DIR" "${paths[@]}" &&
       [[ -s "$CONFIGS_DIR/user.tar" ]]; then
        step_ok "Пользовательские конфиги сохранены"
        return 0
    fi

    step_warn "Не все пользовательские конфиги были сохранены. Подробности в логе."
    return 0
}

backup_assets() {
    mkdir -p "$ASSETS_DIR"

    local saved=0

    if [[ -d "$INSTALL_DIR" ]]; then
        if tar_create_to_file "$ASSETS_DIR/install.tar" -c -C "$SCRIPT_DIR" --exclude='alt_backup' install; then
            saved=1
        else
            step_warn "Не удалось полностью сохранить install-ассеты."
        fi
    fi

    local d rel name
    for d in /var/cache/epm /var/lib/epm; do
        if [[ -d "$d" ]]; then
            rel="${d#/}"
            name="${rel//\//-}"
            if tar_create_to_file "$ASSETS_DIR/${name}.tar" -c -C / "$rel"; then
                saved=1
            else
                step_warn "Не удалось сохранить $d"
            fi
        fi
    done

    if (( saved == 1 )); then
        step_ok "Базовые установочные ассеты сохранены"
    else
        step_warn "Базовые установочные ассеты не найдены или сохранены частично."
    fi

    return 0
}

extract_archive_to_dir() {
    local archive="$1"
    local destdir="$2"

    mkdir -p "$destdir" || return 1

    case "$archive" in
        *.tar.gz|*.tgz|*.tar.bz2|*.tar.xz|*.tar.zst|*.tar)
            local rc=0
            tar -xf "$archive" -C "$destdir" >>"$LOG_FILE" 2>&1 || rc=$?
            (( rc <= 1 ))
            return $?
            ;;
        *.rar)
            if ! command -v unrar >/dev/null 2>&1 &&
               ! command -v unar >/dev/null 2>&1 &&
               ! command -v bsdtar >/dev/null 2>&1 &&
               ! command -v 7z >/dev/null 2>&1 &&
               ! command -v 7za >/dev/null 2>&1; then
                install_package_name p7zip >/dev/null 2>&1 || true
                install_package_name p7zip-full >/dev/null 2>&1 || true
                install_package_name unrar >/dev/null 2>&1 || true
                install_package_name unar >/dev/null 2>&1 || true
            fi

            if command -v unrar >/dev/null 2>&1; then
                if unrar x -inul -y "$archive" "$destdir/" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v unar >/dev/null 2>&1; then
                if unar -force-overwrite -o "$destdir" "$archive" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v bsdtar >/dev/null 2>&1; then
                if bsdtar -xf "$archive" -C "$destdir" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v 7z >/dev/null 2>&1; then
                if 7z x -y -o"$destdir" "$archive" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v 7za >/dev/null 2>&1; then
                if 7za x -y -o"$destdir" "$archive" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            return 1
            ;;
        *.zip)
            if ! command -v unzip >/dev/null 2>&1 &&
               ! command -v bsdtar >/dev/null 2>&1 &&
               ! command -v 7z >/dev/null 2>&1 &&
               ! command -v 7za >/dev/null 2>&1; then
                install_package_name unzip >/dev/null 2>&1 || true
                install_package_name p7zip >/dev/null 2>&1 || true
                install_package_name p7zip-full >/dev/null 2>&1 || true
            fi

            if command -v unzip >/dev/null 2>&1; then
                if unzip -oq "$archive" -d "$destdir" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v bsdtar >/dev/null 2>&1; then
                if bsdtar -xf "$archive" -C "$destdir" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v 7z >/dev/null 2>&1; then
                if 7z x -y -o"$destdir" "$archive" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            if command -v 7za >/dev/null 2>&1; then
                if 7za x -y -o"$destdir" "$archive" >>"$LOG_FILE" 2>&1; then
                    return 0
                fi
            fi

            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

backup_vendor_assets() {
    if (( OPT_SKIP_VENDOR_ASSETS == 1 )); then
        info "Сохранение вендорских каталогов отключено."
        step_ok "Вендорские каталоги пропущены намеренно"
        return 0
    fi

    mkdir -p "$ASSETS_DIR"

    local list
    list="$(mktemp "${TMPDIR:-/tmp}/alt-sync-vendor-list.XXXXXX")" || {
        step_warn "Не удалось создать временный список вендорских объектов."
        return 0
    }

    : > "$list"

    local p root glob f

    for p in "${VENDOR_FIXED_PATHS[@]}"; do
        append_existing_rel_to_list "$list" "$p"
    done

    for root in "${VENDOR_SEARCH_ROOTS[@]}"; do
        if [[ ! -d "/$root" ]]; then
            continue
        fi

        local -a find_args=("/$root" -mindepth 1 -maxdepth 1 '(')
        local first=1

        for glob in "${VENDOR_NAME_GLOBS[@]}"; do
            if (( first )); then
                find_args+=( -iname "$glob" )
                first=0
            else
                find_args+=( -o -iname "$glob" )
            fi
        done

        find_args+=( ')' -print0 )

        while IFS= read -r -d '' f; do
            append_existing_rel_to_list "$list" "${f#/}"
        done < <(find "${find_args[@]}" 2>/dev/null)
    done

    if [[ ! -s "$list" ]]; then
        rm -f "$list"
        step_warn "Вендорские каталоги не найдены."
        return 0
    fi

    sort -z -u -o "$list" "$list" || true

    info "Сохраняю вендорские объекты из /opt, /etc, /usr, /var/lib и т.п."

    if tar_create_to_file "$ASSETS_DIR/vendor-assets.tar" -c -C / --null -T "$list" &&
       [[ -s "$ASSETS_DIR/vendor-assets.tar" ]]; then
        rm -f "$list"
        step_ok "Вендорские каталоги сохранены"
        return 0
    fi

    rm -f "$list"
    step_warn "Не все вендорские каталоги сохранены. Подробности в логе."
    return 0
}

save_hardware_profile() {
    mkdir -p "$LISTS_DIR"
    local out="$LISTS_DIR/hardware.txt"

    {
        printf '=== DMI ===\n'
        local f
        for f in product_name sys_vendor board_name bios_version product_uuid; do
            if [[ -r "/sys/class/dmi/id/$f" ]]; then
                printf '%s=%s\n' "$f" "$(< "/sys/class/dmi/id/$f")"
            fi
        done

        printf '\n=== PCI ===\n'
        if command -v lspci >/dev/null 2>&1; then
            lspci -nn 2>/dev/null || true
        elif command -v lshw >/dev/null 2>&1; then
            lshw -short -C bus 2>/dev/null || true
        else
            printf '%s\n' '(lspci/lshw недоступны)'
        fi

        printf '\n=== USB ===\n'
        if command -v lsusb >/dev/null 2>&1; then
            lsusb 2>/dev/null || true
        else
            find /sys/bus/usb/devices -maxdepth 1 -name '*:*' -printf '%f\n' 2>/dev/null || true
        fi

        printf '\n=== PRINTERS (CUPS) ===\n'
        if command -v lpstat >/dev/null 2>&1; then
            lpstat -p -d 2>/dev/null || true
        fi

        printf '\n=== INPUT/XKB ===\n'
        if command -v localectl >/dev/null 2>&1; then
            localectl status 2>/dev/null || true
        fi

        printf '\n=== KERNEL MODULES (loaded) ===\n'
        if [[ -r /proc/modules ]]; then
            awk '{print $1}' /proc/modules 2>/dev/null | sort || true
        fi

        printf '\n=== SOUND/AUDIO ===\n'
        if command -v aplay >/dev/null 2>&1; then
            aplay -L 2>/dev/null | head -40 || true
        fi
    } > "$out" 2>/dev/null || true

    if [[ -s "$out" ]]; then
        step_ok "Аппаратный профиль сохранён (hardware.txt)"
    else
        rm -f "$out" 2>/dev/null || true
        step_warn "Не удалось собрать аппаратный профиль."
    fi
    return 0
}

save_services_state() {
    mkdir -p "$LISTS_DIR"
    local out="$LISTS_DIR/services_enabled.txt"

    if ! command -v systemctl >/dev/null 2>&1; then
        info "systemctl недоступен — состояние сервисов не сохраняется."
        return 0
    fi

    systemctl list-unit-files --type=service --no-pager 2>/dev/null |
        awk '$2=="enabled"{print $1}' | sort > "$out" || true

    if [[ -s "$out" ]]; then
        step_ok "Список включённых сервисов сохранён ($(wc -l < "$out") шт.)"
    else
        rm -f "$out" 2>/dev/null || true
    fi
    return 0
}

apply_saved_services() {
    local file="$LISTS_DIR/services_enabled.txt"
    [[ -f "$file" ]] || return 0

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    info "Включаю сервисы из эталона..."
    local svc n=0
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if systemctl is-enabled "$svc" >/dev/null 2>&1; then
            continue
        fi
        if systemctl enable "$svc" >>"$LOG_FILE" 2>&1; then
            n=$((n + 1))
        else
            log "Не удалось включить сервис: $svc"
        fi
    done < "$file"

    if (( n > 0 )); then
        step_ok "Дополнительно включено сервисов: $n"
    fi
    return 0
}

compare_hardware_profile() {
    local ref="$LISTS_DIR/hardware.txt"
    [[ -f "$ref" ]] || return 0

    local cur
    cur="$(mktemp "${TMPDIR:-/tmp}/alt-sync-hwcur.XXXXXX")" || return 0
    add_cleanup_tmpdir "$cur"

    {
        printf '=== DMI ===\n'
        local f
        for f in product_name sys_vendor board_name; do
            if [[ -r "/sys/class/dmi/id/$f" ]]; then
                printf '%s=%s\n' "$f" "$(< "/sys/class/dmi/id/$f")"
            fi
        done
        printf '\n=== PCI ===\n'
        command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null || true
        printf '\n=== USB ===\n'
        command -v lsusb >/dev/null 2>&1 && lsusb 2>/dev/null || true
    } > "$cur" 2>/dev/null || true

    if ! diff -u "$ref" "$cur" > "$REPORT_DIR/hardware_diff.txt" 2>/dev/null; then
        step_warn "Железо копии отличается от эталона. Разница: $REPORT_DIR/hardware_diff.txt"
        info "Драйверы для отсутствующего оборудования могут не заработать до подключения периферии."
    else
        step_ok "Железо совпадает с эталоном"
    fi
    return 0
}

make_checksums() {
    local -a targets=()

    [[ -f "$BACKUP_DIR/MANIFEST" ]] && targets+=("MANIFEST")
    [[ -f "$BACKUP_DIR/.machine_id" ]] && targets+=(".machine_id")

    local d
    for d in lists packages configs assets; do
        [[ -d "$BACKUP_DIR/$d" ]] && targets+=("$d")
    done

    if (( ${#targets[@]} == 0 )); then
        return 0
    fi

    (
        cd "$BACKUP_DIR" || exit 1
        find "${targets[@]}" -type f \
            ! -name SHA256SUMS \
            ! -name rpm-index.tsv \
            ! -name Packages \
            ! -name Packages.gz \
            ! -name Release \
            -print0 |
            sort -z |
            xargs -0 -r sha256sum > SHA256SUMS.tmp 2>>"$LOG_FILE"
        mv -f SHA256SUMS.tmp SHA256SUMS
    ) || {
        step_warn "Не удалось создать SHA256SUMS."
        return 0
    }

    step_ok "SHA256SUMS созданы"
    return 0
}

write_summary_report() {
    local action="$1"
    local report
    report="$REPORT_DIR/alt_sync_report_$(date +%Y%m%d_%H%M%S).txt"

    mkdir -p "$REPORT_DIR" 2>/dev/null || return 0

    local elapsed=$(( $(date +%s) - START_TIME ))

    {
        printf 'ALT Linux Universal Sync — итоговый отчёт\n'
        printf 'Действие: %s\n' "$action"
        printf 'Время: %s\n' "$(date '+%F %T')"
        printf 'Длительность: %dм %dс\n' $((elapsed / 60)) $((elapsed % 60))
        printf 'Хост: %s | Пользователь профиля: %s\n' "$(hostname)" "${TARGET_USER:-<не задан>}"
        printf 'Бэкап: %s\n' "$BACKUP_DIR"
        printf 'Лог: %s\n\n' "$LOG_FILE"

        if [[ -f "$BACKUP_DIR/MANIFEST" ]]; then
            printf '--- MANIFEST ---\n'
            cat "$BACKUP_DIR/MANIFEST"
            printf '\n'
        fi

        printf '--- Успешно (%d) ---\n' "${#REPORT_OK_LIST[@]}"
        local i
        for ((i = 0; i < ${#REPORT_OK_LIST[@]}; i++)); do
            printf '  [OK]   %s\n' "${REPORT_OK_LIST[i]}"
        done

        printf '\n--- Предупреждения (%d) ---\n' "${#REPORT_WARN_LIST[@]}"
        if ((${#REPORT_WARN_LIST[@]} == 0)); then
            printf '  (нет)\n'
        else
            for ((i = 0; i < ${#REPORT_WARN_LIST[@]}; i++)); do
                printf '  [WARN] %s\n' "${REPORT_WARN_LIST[i]}"
            done
        fi

        printf '\n--- Ошибки (%d) ---\n' "${#REPORT_FAIL_LIST[@]}"
        if ((${#REPORT_FAIL_LIST[@]} == 0)); then
            printf '  (нет)\n'
        else
            for ((i = 0; i < ${#REPORT_FAIL_LIST[@]}; i++)); do
                printf '  [FAIL] %s\n' "${REPORT_FAIL_LIST[i]}"
            done
        fi

        if [[ -f "$BACKUP_DIR/SHA256SUMS" ]]; then
            printf '\nДля проверки целостности: (cd %s && sha256sum -c SHA256SUMS)\n' "$BACKUP_DIR"
        fi
    } > "$report" 2>/dev/null || {
        step_warn "Не удалось записать итоговый отчёт."
        return 0
    }

    log "Отчёт сохранён: $report"
    printf '%b\n' "${CYAN}  📄 Итоговый отчёт: ${NC}$report"
    return 0
}

do_export() {
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        die "Не удалось создать каталог бэкапа: $BACKUP_DIR"
    fi

    if ! touch "$BACKUP_DIR/.write_test" 2>/dev/null; then
        die "Каталог бэкапа недоступен для записи: $BACKUP_DIR"
    fi
    rm -f "$BACKUP_DIR/.write_test"

    if [[ -d "$BACKUP_DIR/lists" || -d "$BACKUP_DIR/packages" ]]; then
        step_warn "Внимание: существующий бэкап в $BACKUP_DIR будет заменён новым слепком."
        info "Старая копия будет сохранена в ${BACKUP_DIR}.previous до успешного завершения экспорта."
        if ! ask_yes_no "Продолжить экспорт с перезаписью бэкапа?" y; then
            info "Экспорт отменён пользователем — существующий бэкап не тронут."
            return 1
        fi
    fi

    if ! check_machine_match; then
        return 1
    fi

    local prev_snap=""
    if [[ -d "$BACKUP_DIR/lists" || -d "$BACKUP_DIR/packages" ]]; then
        prev_snap="${BACKUP_DIR}.previous"
        if [[ -e "$prev_snap" ]]; then
            step_warn "Каталог $prev_snap уже существует — буду заменять его."
            rm -rf -- "$prev_snap"
        fi
        info "Сохраняю предыдущий бэкап в $prev_snap (на время экспорта)."
        if mv -- "$BACKUP_DIR" "$prev_snap" 2>/dev/null; then
            mkdir -p "$BACKUP_DIR" || die "Не удалось создать каталог бэкапа: $BACKUP_DIR"
            export PREV_BACKUP_SNAP="$prev_snap"
        else
            step_warn "Не удалось переместить старый бэкап — продолжаю с перезаписью."
            prev_snap=""
        fi
    fi

    init_steps 9

    rm -rf "$LISTS_DIR" "$PACKAGES_DIR" "$CONFIGS_DIR" "$ASSETS_DIR"
    rm -f "$BACKUP_DIR/SHA256SUMS"
    mkdir -p "$BACKUP_DIR"/{lists,packages,configs,assets}
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    step_start "Подготовка"
    info "Пользователь: ${TARGET_USER:-<не задан>} (${HOME_DIR:-<нет>})"
    info "Каталог бэкапа: $BACKUP_DIR"
    info "Лог: $LOG_FILE"
    step_ok "Окружение готово"

    step_start "Манифест и списки пакетов"
    write_manifest
    save_package_manifest
    local pkg_count=0
    if [[ -f "$LISTS_DIR/installed_nvra.txt" ]]; then
        pkg_count="$(wc -l < "$LISTS_DIR/installed_nvra.txt")"
    fi
    step_ok "Сохранено пакетов: $pkg_count"

    step_start "Сборка RPM и локального репозитория"
    collect_rpms
    step_ok "Локальные пакеты подготовлены"

    step_start "Аппаратный профиль и состояние сервисов"
    save_hardware_profile
    save_services_state

    step_start "Системные конфигурации"
    backup_system_configs

    step_start "Пользовательские конфигурации"
    backup_user_configs

    step_start "Установочные ассеты и вендорские каталоги"
    backup_assets
    backup_vendor_assets

    step_start "Контрольные суммы"
    make_checksums

    step_start "Завершение экспорта"
    local size
    size="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || true)"
    info "Размер бэкапа: ${size:-неизвестно}"
    info "Логи и отчёты: $LOG_DIR"
    write_summary_report "Экспорт эталона (докачка: $([ "${OPT_DOWNLOAD_MISSING:-0}" == "1" ] && echo включена || echo выключена))"

    if [[ -n "${PREV_BACKUP_SNAP:-}" ]]; then
        rm -rf -- "$PREV_BACKUP_SNAP" 2>/dev/null || true
        unset PREV_BACKUP_SNAP
    fi

    step_ok "Экспорт завершён"

    return 0
}

prepare_local_apt() {
    mkdir -p "$PACKAGES_DIR" 2>/dev/null || true

    LOCAL_SOURCES="/tmp/alt-sync-sources.$$.list"
    LOCAL_SOURCEPARTS="/tmp/alt-sync-sourceparts.$$"

    mkdir -p "$LOCAL_SOURCEPARTS"

    printf 'rpm dir:%s\n' "$PACKAGES_DIR" > "$LOCAL_SOURCES"

    APT_LOCAL=(
        -o "Dir::Etc::sourcelist=$LOCAL_SOURCES"
        -o "Dir::Etc::sourceparts=$LOCAL_SOURCEPARTS"
        -o "Acquire::AllowInsecureRepositories=true"
    )

    APT_LOCAL_ENABLED=0

    log "Подготовлен временный APT-источник: $LOCAL_SOURCES"
}

apt_update_local() {
    local rc

    if command -v timeout >/dev/null 2>&1; then
        timeout 60 apt-get ${APT_LOCAL[@]+"${APT_LOCAL[@]}"} update -qq </dev/null >>"$LOG_FILE" 2>&1
        rc=$?
    else
        apt-get ${APT_LOCAL[@]+"${APT_LOCAL[@]}"} update -qq </dev/null >>"$LOG_FILE" 2>&1
        rc=$?
    fi

    if (( rc == 0 )); then
        APT_LOCAL_ENABLED=1
    fi

    return "$rc"
}

verify_backup() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        step_fail "Бэкап не найден: $BACKUP_DIR"
        return 1
    fi

    if [[ ! -f "$LISTS_DIR/installed_nvra.txt" ]]; then
        step_fail "В бэкапе нет списка пакетов: $LISTS_DIR/installed_nvra.txt"
        return 1
    fi

    if [[ ! -f "$LISTS_DIR/installed_specs.txt" ]]; then
        step_fail "В бэкапе нет списка спецификаций: $LISTS_DIR/installed_specs.txt"
        return 1
    fi

    if [[ -f "$BACKUP_DIR/SHA256SUMS" ]] && (( OPT_VERIFY_BACKUP == 1 )); then
        info "Проверяю SHA256SUMS..."
        if ! (cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS >>"$LOG_FILE" 2>&1); then
            step_fail "Контрольные суммы не совпали."
            return 1
        fi
        step_ok "Контрольные суммы в порядке"
    elif (( OPT_VERIFY_BACKUP == 1 )); then
        step_warn "SHA256SUMS отсутствует, проверка пропущена."
    fi

    return 0
}

confirm_import() {
    if ! ask_yes_no "Подтверждаете импорт? Будут изменены пакеты, /etc, /opt и, возможно, пользовательский профиль." n; then
        info "Импорт отменён пользователем."
        return 1
    fi
    return 0
}

snapshot_before_import() {
    if (( OPT_SNAPSHOT != 1 )); then
        info "Откатной снимок отключён в меню."
        return 0
    fi

    local snap
    snap="/var/backups/alt-sync/pre-import-$(date +%Y%m%d_%H%M%S)"

    if ! mkdir -p "$snap" 2>/dev/null; then
        snap="$LOG_DIR/pre-import-$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$snap" 2>/dev/null || {
            step_warn "Не удалось создать каталог снимка."
            return 0
        }
    fi

    info "Создаю откатной снимок: $snap"

    tar -C / -cf "$snap/etc.tar" etc 2>>"$LOG_FILE" || step_warn "Снимок /etc создан неполностью."

    if [[ -n "${TARGET_USER:-}" && -n "${HOME_DIR:-}" && -d "$HOME_DIR" ]]; then
        local -a paths=()
        local r
        for r in .config .local/share .local/lib .bashrc .profile .cprocsp .crypto-pro .mozilla; do
            if [[ -e "$HOME_DIR/$r" ]]; then
                paths+=("$r")
            fi
        done

        if (( ${#paths[@]} > 0 )); then
            tar -C "$HOME_DIR" -cf "$snap/home.tar" "${paths[@]}" 2>>"$LOG_FILE" || true
        fi
    fi

    log "Откатной снимок: $snap"
    return 0
}

restore_assets() {
    if [[ ! -d "$ASSETS_DIR" ]]; then
        info "Ассеты отсутствуют, пропускаю."
        return 0
    fi

    local archive base

    for archive in "$ASSETS_DIR"/*.tar; do
        if [[ ! -f "$archive" ]]; then
            continue
        fi

        base="$(basename "$archive")"

        case "$base" in
            install.tar)
                if [[ -d "$SCRIPT_DIR/install" ]]; then
                    info "Каталог install уже существует, пропускаю распаковку install.tar."
                else
                    info "Распаковываю install.tar в $SCRIPT_DIR"
                    tar_extract_safe "$archive" "$SCRIPT_DIR" || step_warn "Не удалось полностью распаковать install.tar"
                fi
                ;;
            vendor-assets.tar)
                info "vendor-assets.tar будет восстановлен отдельно."
                ;;
            *)
                info "Распаковываю $base в /"
                tar_extract_preserve "$archive" / || tar_extract_safe "$archive" / || step_warn "Не удалось полностью распаковать $base"
                ;;
        esac
    done

    return 0
}

restore_vendor_assets() {
    local archive="$ASSETS_DIR/vendor-assets.tar"

    if (( OPT_SKIP_VENDOR_RESTORE == 1 )); then
        info "Восстановление вендорских каталогов отключено в меню."
        return 0
    fi

    if [[ ! -f "$archive" ]]; then
        info "vendor-assets.tar не найден — пропускаю восстановление вендорских каталогов."
        return 0
    fi

    info "Восстанавливаю /opt/pantum, /opt/cprocsp, SANE/CUPS/udev/systemd и прочие вендорские объекты"

    if tar_extract_preserve "$archive" /; then
        step_ok "Вендорские каталоги восстановлены"
    elif tar_extract_safe "$archive" /; then
        step_warn "Вендорские каталоги восстановлены без части метаданных."
    else
        step_warn "Не все вендорские каталоги восстановлены."
    fi

    return 0
}

refresh_library_cache() {
    if command -v ldconfig >/dev/null 2>&1; then
        info "Обновляю кэш библиотек (ldconfig)..."
        ldconfig >>"$LOG_FILE" 2>&1 || true
    fi
    return 0
}

install_batch() {
    local failed_file="$1"
    shift

    local -a pkgs=("$@")
    if (( ${#pkgs[@]} == 0 )); then
        return 0
    fi

    if apt_install_local "${pkgs[@]}"; then
        return 0
    fi

    local -a missing=()
    local pkg nvra
    for pkg in "${pkgs[@]}"; do
        nvra="$(spec_to_nvra "$pkg")"
        if ! rpm -q "$nvra" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    local -a group=()
    local spec path cnt=0
    for spec in ${missing[@]+"${missing[@]}"}; do
        path=""
        if [[ -n "${RPM_BY_SPEC[$spec]:-}" ]] && [[ -f "${RPM_BY_SPEC[$spec]}" ]]; then
            path="${RPM_BY_SPEC[$spec]}"
        elif [[ -n "${RPM_BY_NVRA[$(spec_to_nvra "$spec")]:-}" ]] && [[ -f "${RPM_BY_NVRA[$(spec_to_nvra "$spec")]}" ]]; then
            path="${RPM_BY_NVRA[$(spec_to_nvra "$spec")]}"
        fi
        if [[ -n "$path" ]]; then
            group+=("$path")
            cnt=$((cnt + 1))
            if (( cnt >= 50 )); then
                install_rpm_files_group "${group[@]}" || true
                group=(); cnt=0
            fi
        else
            group+=("$spec")
            cnt=$((cnt + 1))
            if (( cnt >= 50 )); then
                install_rpm_files_group "${group[@]}" || true
                group=(); cnt=0
            fi
        fi
    done
    if (( ${#group[@]} > 0 )); then
        install_rpm_files_group "${group[@]}" || true
    fi

    local still_failed=0
    for pkg in "${pkgs[@]}"; do
        nvra="$(spec_to_nvra "$pkg")"
        if rpm -q "$nvra" >/dev/null 2>&1; then
            continue
        fi
        if ! install_spec "$pkg"; then
            echo "$pkg" >> "$failed_file"
            still_failed=$((still_failed + 1))
        fi
    done

    if (( still_failed > 0 )); then
        log "После групповых попыток не установлены $still_failed позиц(ий) из batches — см. $failed_file"
    fi

    return 0
}

verify_installed_manifest() {
    local nvra_file="$LISTS_DIR/installed_nvra.txt"
    if [[ ! -f "$nvra_file" ]]; then
        return 0
    fi

    local out="$REPORT_DIR/missing_installed.txt"
    mkdir -p "$REPORT_DIR"
    : > "$out"

    local nvra missing_count=0
    while IFS= read -r nvra; do
        if [[ -z "$nvra" ]]; then
            continue
        fi

        if ! rpm -q "$nvra" >/dev/null 2>&1; then
            echo "$nvra" >> "$out"
            missing_count=$((missing_count + 1))
        fi
    done < "$nvra_file"

    if (( missing_count > 0 )); then
        step_warn "Не установлены $missing_count пакетов из эталона. Список: $out"
    else
        step_ok "Все пакеты из эталонного списка присутствуют"
    fi

    return 0
}

install_manifest_packages() {
    local spec_file="$LISTS_DIR/installed_specs.txt"
    if [[ ! -f "$spec_file" ]]; then
        step_warn "Файл installed_specs.txt не найден."
        return 0
    fi

    ensure_rpm_index

    if (( APT_LOCAL_ENABLED != 1 )) || (( OPT_NETWORK_ENABLED != 1 )); then
        install_local_rpm_directory_fallback
    fi

    local total
    total="$(wc -l < "$spec_file")"

    local failed_file="$REPORT_DIR/failed_specs.txt"
    mkdir -p "$REPORT_DIR"
    : > "$failed_file"

    local -a batch=()
    local spec
    local processed=0

    progress_reset

    while IFS= read -r spec; do
        if [[ -z "$spec" ]]; then
            continue
        fi

        batch+=("$spec")
        processed=$((processed + 1))
        progress_bar "$processed" "$total" "Пакеты эталона" "${spec%%=*}"

        if (( ${#batch[@]} >= 50 )); then
            install_batch "$failed_file" "${batch[@]}"
            batch=()
        fi
    done < "$spec_file"

    if (( ${#batch[@]} > 0 )); then
        install_batch "$failed_file" "${batch[@]}"
    fi

    if (( total > 0 && processed >= total )); then
        printf '\n'
    fi

    if [[ -s "$failed_file" ]]; then
        step_warn "Часть пакетов не установлена. Список: $failed_file"
    fi

    verify_installed_manifest
    return 0
}

install_special_packages() {
    update_system_lists_if_needed
    ensure_rpm_index

    declare -A seen=()
    local pkg

    for pkg in "${EPSON_PKGS[@]}" "${PANTUM_PKGS[@]}" "${CRYPTO_PKGS[@]}"; do
        if [[ -n "${seen[$pkg]:-}" ]]; then
            continue
        fi
        seen[$pkg]=1

        if install_package_name "$pkg"; then
            log "Специальный пакет установлен/присутствует: $pkg"
        else
            step_warn "Не удалось установить специальный пакет: $pkg"
        fi
    done

    return 0
}

install_pantum() {
    if [[ ( -d /opt/pantum || -d /usr/lib/pantum || -d /usr/share/pantum ) ]] &&
       (( OPT_FORCE_EPM_PLAY != 1 )); then
        info "Pantum уже восстановлен из бэкапа (/opt/pantum или /usr/*/pantum)."
        info "Пропускаю epm play pantum. Его можно принудительно запустить через меню импорта."
        return 0
    fi

    if ! install_package_name epm; then
        step_warn "epm не установлен, установка Pantum пропущена."
        return 0
    fi

    if ! command -v epm >/dev/null 2>&1; then
        step_warn "Команда epm недоступна, Pantum пропущен."
        return 0
    fi

    info "Устанавливаю Pantum через epm play pantum..."

    if epm play --yes pantum </dev/null >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    if epm play -y pantum </dev/null >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    step_warn "Не удалось установить Pantum в неинтерактивном режиме."

    return 0
}

CRYPTO_SEARCH_PREPARED=0
CRYPTO_SEARCH_DIRS=()
CRYPTO_INSTALLER_DIR=""

add_crypto_search_dir() {
    local d="$1"
    [[ -d "$d" ]] || return 0

    local existing
    for existing in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        if [[ "$existing" == "$d" ]]; then
            return 0
        fi
    done

    CRYPTO_SEARCH_DIRS+=("$d")
}

prepare_crypto_search_dirs() {
    if (( CRYPTO_SEARCH_PREPARED == 1 )); then
        return 0
    fi

    CRYPTO_SEARCH_DIRS=()

    add_crypto_search_dir "$SCRIPT_DIR/install"
    add_crypto_search_dir "$BACKUP_DIR/install"

    if [[ -f "$ASSETS_DIR/install.tar" ]]; then
        local tmp
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-install-tar.XXXXXX")" || {
            CRYPTO_SEARCH_PREPARED=1
            return 0
        }

        add_cleanup_tmpdir "$tmp"

        tar_extract_safe "$ASSETS_DIR/install.tar" "$tmp" || true

        add_crypto_search_dir "$tmp/install"
        add_crypto_search_dir "$tmp"
    fi

    CRYPTO_SEARCH_PREPARED=1
}

find_crypto_installer() {
    CRYPTO_INSTALLER_DIR=""
    prepare_crypto_search_dirs

    local d f

    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        f="$(find "$d" -maxdepth 4 -type f -name install_gui.sh -print -quit 2>/dev/null || true)"
        if [[ -n "$f" ]]; then
            CRYPTO_INSTALLER_DIR="$(dirname "$f")"
            return 0
        fi
    done

    local archive extract_dir
    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        archive="$(
            find "$d" -maxdepth 4 -type f \
                \( -name 'linux-amd64.tgz' -o -name 'linux-amd64.tar.gz' \) \
                -print -quit 2>/dev/null || true
        )"

        if [[ -n "$archive" ]]; then
            extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-crypto-extracted.XXXXXX")" || continue
            add_cleanup_tmpdir "$extract_dir"

            if extract_archive_to_dir "$archive" "$extract_dir"; then
                f="$(find "$extract_dir" -maxdepth 4 -type f -name install_gui.sh -print -quit 2>/dev/null || true)"
                if [[ -n "$f" ]]; then
                    CRYPTO_INSTALLER_DIR="$(dirname "$f")"
                    return 0
                fi
            fi
        fi
    done

    return 1
}

install_cryptopro_rpms_from_sources() {
    prepare_crypto_search_dirs

    local list
    list="$(mktemp "${TMPDIR:-/tmp}/alt-sync-crypto-rpms.XXXXXX")" || return 1
    : > "$list"

    local -a search_dirs=()
    [[ -d "$PACKAGES_DIR" ]] && search_dirs+=("$PACKAGES_DIR")

    local d
    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        [[ -d "$d" ]] && search_dirs+=("$d")
    done

    if (( ${#search_dirs[@]} == 0 )); then
        rm -f "$list"
        return 1
    fi

    local archive extract_dir f

    find "${search_dirs[@]}" -type f -name '*.rpm' \
        \( -iname '*cprocsp*' -o -iname '*cryptopro*' -o -iname '*librtpkcs11ecp*' \) \
        ! -iname '*kc2*' -print0 2>/dev/null >> "$list" || true

    while IFS= read -r -d '' archive; do
        extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-crypto-archive.XXXXXX")" || continue
        add_cleanup_tmpdir "$extract_dir"

        if extract_archive_to_dir "$archive" "$extract_dir"; then
            find "$extract_dir" -type f -name '*.rpm' \
                \( -iname '*cprocsp*' -o -iname '*cryptopro*' -o -iname '*librtpkcs11ecp*' \) \
                ! -iname '*kc2*' -print0 2>/dev/null >> "$list" || true
        fi
    done < <(
        find "${search_dirs[@]}" -type f \
            \( -name 'linux-amd64.tgz' -o -name 'linux-amd64.tar.gz' \) \
            -print0 2>/dev/null || true
    )

    if [[ ! -s "$list" ]]; then
        rm -f "$list"
        return 1
    fi

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(sort -z -u "$list")

    rm -f "$list"

    if (( ${#files[@]} == 0 )); then
        return 1
    fi

    if install_rpm_files_group "${files[@]}"; then
        info "CryptoPro RPM установлены группой из локальных источников: ${#files[@]}"
        return 0
    fi

    local count=0
    for f in "${files[@]}"; do
        if install_rpm_file "$f"; then
            count=$((count + 1))
        else
            step_warn "Не установлен CryptoPro RPM: $f"
        fi
    done

    if (( count > 0 )); then
        info "Установлено CryptoPro RPM из локальных источников: $count"
        return 0
    fi

    return 1
}

install_librtpkcs11ecp_from_archives() {
    prepare_crypto_search_dirs

    local -a search_dirs=()
    [[ -d "$PACKAGES_DIR" ]] && search_dirs+=("$PACKAGES_DIR")

    local d
    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        [[ -d "$d" ]] && search_dirs+=("$d")
    done

    if (( ${#search_dirs[@]} == 0 )); then
        return 1
    fi

    local archive extract_dir rpm_found

    while IFS= read -r -d '' archive; do
        extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-librtpkcs11ecp.XXXXXX")" || continue
        add_cleanup_tmpdir "$extract_dir"

        if extract_archive_to_dir "$archive" "$extract_dir"; then
            rpm_found="$(
                find "$extract_dir" -maxdepth 3 -type f -name 'librtpkcs11ecp*.rpm' -print -quit 2>/dev/null || true
            )"

            if [[ -n "$rpm_found" ]]; then
                if install_rpm_file "$rpm_found"; then
                    return 0
                fi
            fi
        fi
    done < <(
        find "${search_dirs[@]}" -type f \
            \( -iname 'librtpkcs11ecp*.rar' -o -iname 'librtpkcs11ecp*.zip' \) \
            -print0 2>/dev/null || true
    )

    return 1
}

enable_crypto_services() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    local unit
    while IFS= read -r unit; do
        if [[ -z "$unit" ]]; then
            continue
        fi

        if ! systemctl enable --now "$unit" >>"$LOG_FILE" 2>&1; then
            step_warn "Не удалось включить сервис: $unit"
        fi
    done < <(
        systemctl list-unit-files --type=service 2>/dev/null |
        awk '/cprocsp|cryptopro/ {print $1}'
    )

    return 0
}

install_cryptopro() {
    prepare_crypto_search_dirs
    ensure_rpm_index

    info "Устанавливаю cryptopro-preinstall..."
    if ! install_package_name cryptopro-preinstall; then
        step_warn "cryptopro-preinstall не установлен. Возможно, нужен интернет или RPM в локальном репозитории."
    fi

    info "Пробую установить RPM КриптоПро из локальных архивов/папок..."
    if ! install_cryptopro_rpms_from_sources; then
        info "Локальные RPM КриптоПро не найдены или не установились."
    fi

    if [[ -d /opt/cprocsp ]] && (( OPT_FORCE_CRYPTO_INSTALLER != 1 )); then
        if rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -qiE 'cprocsp|cryptopro'; then
            info "/opt/cprocsp и пакеты CryptoPro уже присутствуют. Пропускаю install_gui.sh."
            info "Принудительный запуск установщика можно выбрать в меню CryptoPro/импорта."
        fi
    else
        CRYPTO_INSTALLER_DIR=""
        find_crypto_installer || true
        local installer_dir="$CRYPTO_INSTALLER_DIR"

        if [[ -n "$installer_dir" ]]; then
            info "Найден установщик CryptoPro: $installer_dir"

            if [[ -t 0 && -t 1 ]]; then
                printf '%b\n' "${BOLD}  ➡️  Запускаю install_gui.sh. В установщике выберите все компоненты, кроме «Провайдер KC2».${NC}"
                log "Запуск CryptoPro install_gui.sh из: $installer_dir"

                if ! (
                    cd "$installer_dir" || exit 1
                    if [[ -x ./install_gui.sh ]]; then
                        ./install_gui.sh
                    else
                        bash ./install_gui.sh
                    fi
                ); then
                    step_warn "Установщик CryptoPro завершился с ошибкой или был прерван."
                fi
            else
                step_warn "Нет интерактивного терминала. Выполните вручную:"
                printf '      cd %q && su -c %q\n' "$installer_dir" "bash ./install_gui.sh"
            fi
        else
            step_warn "install_gui.sh не найден. Локальные RPM КриптоПро уже пробовались выше."
        fi
    fi

    local -a search_dirs=()
    [[ -d "$PACKAGES_DIR" ]] && search_dirs+=("$PACKAGES_DIR")

    local d
    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        [[ -d "$d" ]] && search_dirs+=("$d")
    done

    local lrpm=""
    if (( ${#search_dirs[@]} > 0 )); then
        lrpm="$(
            find "${search_dirs[@]}" -type f -name 'librtpkcs11ecp*.rpm' -print -quit 2>/dev/null || true
        )"
    fi

    if [[ -n "$lrpm" ]]; then
        info "Устанавливаю PKCS#11 библиотеку: $lrpm"
        if ! install_rpm_file "$lrpm"; then
            step_warn "Не удалось установить librtpkcs11ecp из файла: $lrpm"
        fi
    else
        info "Ищу librtpkcs11ecp в архивах .rar/.zip..."
        if install_librtpkcs11ecp_from_archives; then
            info "librtpkcs11ecp установлен из архива."
        else
            info "Ищу пакет librtpkcs11ecp через APT..."
            if ! install_package_name librtpkcs11ecp; then
                step_warn "librtpkcs11ecp не найден ни как RPM, ни как архив, ни как пакет APT."
            fi
        fi
    fi

    enable_crypto_services
    return 0
}

restore_system_configs() {
    local archive="$CONFIGS_DIR/system.tar"
    if [[ ! -f "$archive" ]]; then
        step_warn "system.tar не найден, пропускаю восстановление системных конфигов."
        return 0
    fi

    info "Восстанавливаю системные конфиги из system.tar"
    if ! tar_extract_preserve "$archive" /; then
        step_warn "Не все системные конфиги были восстановлены."
    fi

    return 0
}

restore_user_configs() {
    if [[ -z "${TARGET_USER:-}" ]] || (( OPT_RESTORE_USER != 1 )); then
        info "Пользовательский профиль не задан, пропускаю восстановление user-конфигов."
        return 0
    fi

    local archive="$CONFIGS_DIR/user.tar"
    if [[ ! -f "$archive" ]]; then
        step_warn "user.tar не найден, пропускаю восстановление пользовательских конфигов."
        return 0
    fi

    info "Восстанавливаю пользовательские конфиги в $HOME_DIR"

    if ! tar_extract_preserve "$archive" "$HOME_DIR"; then
        if ! tar_extract_safe "$archive" "$HOME_DIR"; then
            step_warn "Не все пользовательские конфиги были восстановлены."
        fi
    fi

    local -a chown_paths=()
    local r
    for r in .config .local .bashrc .profile .cprocsp .crypto-pro .mozilla; do
        if [[ -e "$HOME_DIR/$r" ]]; then
            chown_paths+=("$HOME_DIR/$r")
        fi
    done

    if (( ${#chown_paths[@]} > 0 )); then
        chown -R "${TARGET_USER}:${TARGET_GROUP}" "${chown_paths[@]}" 2>>"$LOG_FILE" || true
    fi

    return 0
}

try_restart_service() {
    local svc="$1"
    local seconds="${2:-15}"

    if command -v systemctl >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout "$seconds" systemctl restart "$svc" >>"$LOG_FILE" 2>&1
        else
            systemctl restart "$svc" >>"$LOG_FILE" 2>&1
        fi
        return $?
    fi

    return 1
}

post_import_services() {
    if command -v udevadm >/dev/null 2>&1; then
        info "Перезагружаю udev-правила..."
        udevadm control --reload-rules >>"$LOG_FILE" 2>&1 || true
        udevadm trigger >>"$LOG_FILE" 2>&1 || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    fi

    if command -v lpstat >/dev/null 2>&1 || [[ -d /etc/cups ]]; then
        info "Перезапускаю CUPS..."
        if ! try_restart_service cups 15; then
            step_warn "Не удалось перезапустить CUPS."
        fi
    fi

    if [[ -d /etc/sane.d ]] || command -v scanimage >/dev/null 2>&1; then
        info "Перезапускаю saned, если он есть..."
        try_restart_service saned 10 || true
    fi

    local svc
    for svc in pcscd pcsc-lite; do
        try_restart_service "$svc" 10 || true
    done

    enable_crypto_services
    refresh_library_cache

    return 0
}

do_import() {
    if ! confirm_import; then
        return 1
    fi

    if ! verify_backup; then
        if ! ask_yes_no "Проверка бэкапа не пройдена. Всё равно продолжить импорт?" n; then
            return 1
        fi
        step_warn "Импорт продолжается по вашему выбору, несмотря на ошибку проверки."
    fi

    init_steps 10

    step_start "Проверка бэкапа и подготовка"
    info "Бэкап: $BACKUP_DIR"
    info "Пользователь: ${TARGET_USER:-<не задан>}"
    info "Лог: $LOG_FILE"
    step_ok "Подготовка завершена"

    step_start "Откатной снимок"
    snapshot_before_import
    step_ok "Снимок готов или отключён"

    step_start "Восстановление ассетов и вендорских каталогов"
    restore_assets
    restore_vendor_assets
    refresh_library_cache
    step_ok "Ассеты восстановлены"

    step_start "Локальный индекс RPM и APT-репозиторий"
    ensure_rpm_index
    prepare_local_apt

    if apt_update_local; then
        step_ok "Локальный репозиторий подключён через rpm dir:"
    else
        info "Пробую альтернативный синтаксис источника: dir:"
        printf 'dir:%s\n' "$PACKAGES_DIR" > "$LOCAL_SOURCES"

        if apt_update_local; then
            step_ok "Локальный репозиторий подключён через dir:"
        else
            step_warn "Не удалось обновить списки локального репозитория. Продолжаю с прямой установкой RPM по индексу."
        fi
    fi

    step_start "Установка пакетов по эталону"
    install_manifest_packages
    step_ok "Пакеты эталона обработаны"

    step_start "Epson / EPM / cryptopro-preinstall"
    install_special_packages
    step_ok "Специальные пакеты обработаны"

    step_start "Pantum"
    install_pantum
    step_ok "Pantum обработан"

    step_start "КриптоПро"
    install_cryptopro
    step_ok "КриптоПро обработано"

    step_start "Восстановление конфигураций"
    restore_system_configs
    restore_user_configs
    step_ok "Конфигурации восстановлены"

    step_start "Сервисы и финализация"
    post_import_services
    apply_saved_services
    compare_hardware_profile
    cleanup_local_apt

    local elapsed
    elapsed=$(( $(date +%s) - START_TIME ))

    printf '\n%b\n' "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
    printf '%b\n' "${GREEN}${BOLD}✅ ИМПОРТ ЗАВЕРШЁН ($((elapsed / 60))м $((elapsed % 60))с)${NC}"
    printf '%b\n' "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
    printf '%b\n' "${CYAN}  ℹ️  Логи и отчёты: ${NC}$LOG_DIR"
    write_summary_report "Импорт на копию железа (сеть: $([ "${OPT_USE_NETWORK_IMPORT:-0}" == "1" ] && echo включена || echo выключена))"
    printf '%b\n\n' "${CYAN}  ℹ️  Для полного применения некоторых драйверов/прошивок может потребоваться перезагрузка.${NC}"

    log "Import finished in ${elapsed}s"
    return 0
}

do_cryptopro_only() {
    init_steps 3

    step_start "Восстановление install-ассетов"
    restore_assets
    step_ok "Ассеты обработаны"

    step_start "Локальный репозиторий, если он есть"
    ensure_rpm_index

    if [[ -d "$PACKAGES_DIR" ]]; then
        prepare_local_apt

        if ! apt_update_local; then
            printf 'dir:%s\n' "$PACKAGES_DIR" > "$LOCAL_SOURCES"
            apt_update_local || step_warn "Локальный репозиторий не обновился."
        fi
    else
        info "Локальный каталог packages не найден, буду использовать системные репозитории и файлы из install/."
    fi
    step_ok "Подготовка завершена"

    step_start "Установка КриптоПро и дополнительных RPM"
    update_system_lists_if_needed
    install_cryptopro
    cleanup_local_apt
    step_ok "КриптоПро готово"

    write_summary_report "Установка только CryptoPro + доп. RPM"
    return 0
}

do_verify() {
    init_steps 1
    step_start "Проверка бэкапа"
    if verify_backup; then
        step_ok "Бэкап выглядит корректно"
        return 0
    fi
    return 1
}

detect_default_user() {
    local u=""

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        u="$SUDO_USER"
    fi

    if [[ -z "$u" && -n "${ALT_SYNC_ORIG_USER:-}" && "${ALT_SYNC_ORIG_USER}" != "root" ]]; then
        u="$ALT_SYNC_ORIG_USER"
    fi

    if [[ -z "$u" ]]; then
        u="$(who 2>/dev/null | awk '$1 != "root" && $1 != "" {print $1; exit}' || true)"
    fi

    if [[ -z "$u" ]] && command -v logname >/dev/null 2>&1; then
        u="$(logname 2>/dev/null || true)"
    fi

    if [[ "$u" == "root" ]]; then
        u=""
    fi

    printf '%s' "$u"
}

validate_user() {
    if [[ -z "${TARGET_USER:-}" ]]; then
        step_warn "Имя пользователя не задано."
        return 1
    fi

    if [[ "$TARGET_USER" == "root" ]]; then
        step_warn "Нельзя использовать root для пользовательского профиля."
        return 1
    fi

    HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
        step_warn "Домашний каталог не найден для пользователя: $TARGET_USER"
        return 1
    fi

    TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    return 0
}

choose_target_user() {
    local default_user
    default_user="$(detect_default_user)"

    if [[ "$NONINTERACTIVE" == "1" ]]; then
        TARGET_USER="${ALT_SYNC_TARGET_USER:-$default_user}"
        if [[ -z "$TARGET_USER" ]]; then
            step_warn "Неинтерактивный режим: пользователь не задан (ALT_SYNC_TARGET_USER)."
            return 1
        fi
    elif [[ -n "$default_user" ]]; then
        if ask_yes_no "Использовать пользователя '$default_user'?" y; then
            TARGET_USER="$default_user"
        else
            printf 'Введите имя пользователя: '
            if [[ -n "$INPUT_TTY" ]]; then
                if ! IFS= read -r TARGET_USER <"$INPUT_TTY"; then
                    return 1
                fi
            elif ! IFS= read -r TARGET_USER; then
                return 1
            fi
        fi
    else
        printf 'Введите имя пользователя для профиля: '
        if [[ -n "$INPUT_TTY" ]]; then
            if ! IFS= read -r TARGET_USER <"$INPUT_TTY"; then
                return 1
            fi
        elif ! IFS= read -r TARGET_USER; then
            return 1
        fi
    fi

    TARGET_USER="$(printf '%s' "$TARGET_USER" | tr -d '[:space:]')"

    if ! validate_user; then
        return 1
    fi

    info "Выбран пользователь: $TARGET_USER ($HOME_DIR)"
    return 0
}

prepare_export() {
    local download="$1"

    OPT_DOWNLOAD_MISSING="$download"
    OPT_NETWORK_ENABLED="$download"
    SYSTEM_LISTS_UPDATED=0

    if [[ "$NONINTERACTIVE" == "1" ]]; then
        if [[ "${ALT_SYNC_BACKUP_MOZILLA:-0}" == "1" || "${ALT_SYNC_ASSUME_YES:-0}" == "1" ]]; then
            OPT_SKIP_MOZILLA=0
        else
            OPT_SKIP_MOZILLA=1
        fi
        if [[ "${ALT_SYNC_BACKUP_NETWORK_KEYS:-0}" == "1" || "${ALT_SYNC_ASSUME_YES:-0}" == "1" ]]; then
            OPT_BACKUP_NETWORK_KEYS=1
        else
            OPT_BACKUP_NETWORK_KEYS=0
        fi
    fi

    local full_auto=0
    if [[ "$NONINTERACTIVE" == "1" && "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        full_auto=1
    elif [[ "$NONINTERACTIVE" == "1" && "${ALT_SYNC_ASSUME_YES:-0}" != "1" && ! -t 0 ]]; then
        full_auto=1
    fi

    if (( full_auto )); then
        OPT_SKIP_VENDOR_ASSETS=0
        OPT_BACKUP_USER=1
        if [[ -n "${ALT_SYNC_TARGET_USER:-}" ]]; then
            TARGET_USER="$ALT_SYNC_TARGET_USER"
        else
            TARGET_USER="$(detect_default_user)"
        fi
        if [[ -z "$TARGET_USER" ]] || ! validate_user; then
            step_warn "Не задан/недействителен пользователь профиля (ALT_SYNC_TARGET_USER) — профиль пропущен."
            TARGET_USER=""; HOME_DIR=""; TARGET_GROUP=""
            OPT_BACKUP_USER=0
            OPT_SKIP_MOZILLA=1
        else
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
        fi
        return 0
    fi

    if ask_yes_no "Сохранять вендорские каталоги (/opt/pantum, /opt/cprocsp, sane/cups/udev и т.п.)?" y; then
        OPT_SKIP_VENDOR_ASSETS=0
    else
        OPT_SKIP_VENDOR_ASSETS=1
    fi

    if ask_yes_no "Сохранять пользовательский профиль?" y; then
        if ! choose_target_user; then
            return 1
        fi
        OPT_BACKUP_USER=1

        if ask_yes_no "Включать в бэкап ~/.mozilla (браузерные пароли, cookies, профили)?" n; then
            OPT_SKIP_MOZILLA=0
        else
            OPT_SKIP_MOZILLA=1
        fi

        if ask_yes_no "Включать в бэкап сетевые профили (Wi-Fi пароли NetworkManager)?" n; then
            OPT_BACKUP_NETWORK_KEYS=1
        else
            OPT_BACKUP_NETWORK_KEYS=0
        fi
    else
        TARGET_USER=""
        HOME_DIR=""
        TARGET_GROUP=""
        OPT_BACKUP_USER=0
        OPT_SKIP_MOZILLA=1
    fi

    return 0
}

prepare_import_interactive() {
    if [[ "$NONINTERACTIVE" == "1" && "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        OPT_VERIFY_BACKUP=1
        OPT_SNAPSHOT=1
        OPT_SKIP_VENDOR_RESTORE=0
        OPT_USE_NETWORK_IMPORT=1
        OPT_NETWORK_ENABLED=1
        SYSTEM_LISTS_UPDATED=0
        OPT_FORCE_EPM_PLAY=0
        OPT_FORCE_CRYPTO_INSTALLER=0
        OPT_ALLOW_NODEPS=0
        if [[ -n "${ALT_SYNC_TARGET_USER:-}" ]] && validate_user; then
            TARGET_USER="$ALT_SYNC_TARGET_USER"
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
            OPT_RESTORE_USER=1
        else
            step_warn "Не задан/недействителен пользователь профиля (ALT_SYNC_TARGET_USER) — профиль не восстанавливается."
            TARGET_USER=""; HOME_DIR=""; TARGET_GROUP=""
            OPT_RESTORE_USER=0
        fi
        return 0
    fi

    if ask_yes_no "Проверять SHA256SUMS перед импортом?" y; then
        OPT_VERIFY_BACKUP=1
    else
        OPT_VERIFY_BACKUP=0
    fi

    if ask_yes_no "Делать откатной снимок /etc и профиля перед импортом?" y; then
        OPT_SNAPSHOT=1
    else
        OPT_SNAPSHOT=0
    fi

    if ask_yes_no "Восстанавливать вендорские каталоги из vendor-assets.tar?" y; then
        OPT_SKIP_VENDOR_RESTORE=0
    else
        OPT_SKIP_VENDOR_RESTORE=1
    fi

    if ask_yes_no "Восстанавливать пользовательский профиль?" y; then
        if ! choose_target_user; then
            return 1
        fi
        OPT_RESTORE_USER=1
    else
        TARGET_USER=""
        HOME_DIR=""
        TARGET_GROUP=""
        OPT_RESTORE_USER=0
    fi

    if ask_yes_no "Использовать интернет для докачки/обновления списков/epm/CryptoPreinstall?" y; then
        OPT_USE_NETWORK_IMPORT=1
    else
        OPT_USE_NETWORK_IMPORT=0
    fi

    OPT_NETWORK_ENABLED="$OPT_USE_NETWORK_IMPORT"
    SYSTEM_LISTS_UPDATED=0

    if ask_yes_no "Принудительно запускать epm play pantum, даже если Pantum уже восстановлен?" n; then
        OPT_FORCE_EPM_PLAY=1
    else
        OPT_FORCE_EPM_PLAY=0
    fi

    if ask_yes_no "Принудительно запускать установщик CryptoPro, даже если /opt/cprocsp уже восстановлен?" n; then
        OPT_FORCE_CRYPTO_INSTALLER=1
    else
        OPT_FORCE_CRYPTO_INSTALLER=0
    fi

    if ask_yes_no "Разрешить rpm --nodeps как крайнюю меру?" n; then
        OPT_ALLOW_NODEPS=1
    else
        OPT_ALLOW_NODEPS=0
    fi

    return 0
}

prepare_import_offline() {
    OPT_VERIFY_BACKUP=1
    OPT_SNAPSHOT=1

    if [[ "$NONINTERACTIVE" == "1" && "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        OPT_SKIP_VENDOR_RESTORE=0
        OPT_USE_NETWORK_IMPORT=0
        OPT_NETWORK_ENABLED=0
        SYSTEM_LISTS_UPDATED=0
        OPT_FORCE_EPM_PLAY=0
        OPT_FORCE_CRYPTO_INSTALLER=0
        OPT_ALLOW_NODEPS=0
        if [[ -n "${ALT_SYNC_TARGET_USER:-}" ]] && validate_user; then
            TARGET_USER="$ALT_SYNC_TARGET_USER"
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
            OPT_RESTORE_USER=1
        else
            step_warn "Не задан/недействителен пользователь профиля (ALT_SYNC_TARGET_USER) — профиль не восстанавливается."
            TARGET_USER=""; HOME_DIR=""; TARGET_GROUP=""
            OPT_RESTORE_USER=0
        fi
        return 0
    fi

    if ask_yes_no "Восстанавливать пользовательский профиль?" y; then
        if ! choose_target_user; then
            return 1
        fi
        OPT_RESTORE_USER=1
    else
        TARGET_USER=""
        HOME_DIR=""
        TARGET_GROUP=""
        OPT_RESTORE_USER=0
    fi

    OPT_USE_NETWORK_IMPORT=0
    OPT_NETWORK_ENABLED=0
    SYSTEM_LISTS_UPDATED=0

    OPT_FORCE_EPM_PLAY=0
    OPT_FORCE_CRYPTO_INSTALLER=0
    OPT_ALLOW_NODEPS=0

    return 0
}

prepare_crypto_interactive() {
    if [[ "$NONINTERACTIVE" == "1" && "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        OPT_NETWORK_ENABLED=1
        SYSTEM_LISTS_UPDATED=0
        OPT_FORCE_CRYPTO_INSTALLER=0
        OPT_ALLOW_NODEPS=0
        return 0
    fi

    if ask_yes_no "Использовать интернет для cryptopro-preinstall/дополнительных пакетов?" y; then
        OPT_NETWORK_ENABLED=1
    else
        OPT_NETWORK_ENABLED=0
    fi

    SYSTEM_LISTS_UPDATED=0

    if ask_yes_no "Принудительно запускать install_gui.sh, даже если CryptoPro уже частично установлен?" n; then
        OPT_FORCE_CRYPTO_INSTALLER=1
    else
        OPT_FORCE_CRYPTO_INSTALLER=0
    fi

    if ask_yes_no "Разрешить rpm --nodeps как крайнюю меру?" n; then
        OPT_ALLOW_NODEPS=1
    else
        OPT_ALLOW_NODEPS=0
    fi

    return 0
}

show_menu() {
    printf '\n%b\n' "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${BOLD}${CYAN}║      ALT LINUX UNIVERSAL SYNC / EXACT HARDWARE       ║${NC}"
    printf '%b\n' "${BOLD}${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}1${NC}) Экспорт эталона: с докачкой недостающих RPM     ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}2${NC}) Экспорт эталона: только локальные RPM            ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${YELLOW}3${NC}) Импорт на копию железа: интерактивный            ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${YELLOW}4${NC}) Импорт на копию железа: полностью офлайн       ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${BLUE}5${NC}) Только CryptoPro + доп. RPM                    ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${CYAN}6${NC}) Проверить бэкап                                ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}7${NC}) Скачать компоненты в офлайн-кэш (нужен инет)  ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${RED}0${NC}) Выход                                          ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}"

    printf '%b\n' "  ${BOLD}Скрипт:${NC} $SELF"
    printf '%b\n' "  ${BOLD}Бэкап:${NC} $BACKUP_DIR"
    printf '%b\n' "  ${BOLD}Лог:${NC} $LOG_FILE"
    if deps_cache_available; then
        local nrpm
        nrpm="$(find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)"
        printf '%b\n' "  ${BOLD}Офлайн-кэш зависимостей:${NC} ${GREEN}${nrpm} RPM${NC} ($DEPS_CACHE_DIR)"
    else
        printf '%b\n' "  ${BOLD}Офлайн-кэш зависимостей:${NC} ${YELLOW}отсутствует${NC} (на эталоне выполните: sudo $SELF fetch-deps)"
    fi

    if [[ -d "$PACKAGES_DIR" ]]; then
        local npkg nfree
        npkg="$(find "$PACKAGES_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)"
        nfree="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
        printf '%b\n' "  ${BOLD}Пакеты в бэкапе:${NC} ${npkg:-0} RPM ${CYAN}(свободно на диске: ${nfree:-?} МБ)${NC}"
    fi

    if [[ -r "$MACHINE_ID_FILE" ]]; then
        local cur stor
        cur="$(generate_machine_id)"
        stor="$(tr -d '\r\n ' < "$MACHINE_ID_FILE" 2>/dev/null || true)"
        if [[ "$cur" == "$stor" ]]; then
            printf '%b\n' "  🔒 Статус: ${GREEN}Эталон совпадает${NC}"
        else
            printf '%b\n' "  🔒 Статус: ${RED}Чужая машина${NC}"
        fi
    elif [[ -f "$MACHINE_ID_FILE" ]]; then
        printf '%b\n' "  🔒 Статус: ${YELLOW}Маркер существует, но не читается${NC}"
    else
        printf '%b\n' "  🔒 Статус: ${YELLOW}Маркер эталона ещё не создан${NC}"
    fi

    echo
}

usage() {
    cat <<EOF
ALT Linux Universal Sync v$SCRIPT_VERSION

Интерактивный запуск (по умолчанию):
  $0

CLI-режим (для автоматизации; без аргументов — интерактивное меню):
  $0 <действие> [флаги]

Действия:
  export            Экспорт эталона (аналог меню 1, с докачкой RPM из сети)
  export-offline    Экспорт эталона только из локальных RPM (аналог меню 2)
  import            Интерактивный импорт на копию железа (аналог меню 3)
  import-offline    Полностью офлайн-импорт (аналог меню 4)
  cryptopro         Только CryptoPro + доп. RPM (аналог меню 5)
  verify            Проверка бэкапа (аналог меню 6)
  fetch-deps        [ЭТАЛОН, нужен интернет] Скачать все зависимости скрипта
                    в офлайн-кэш deps-rpm/ рядом со скриптом — для установки
                    на компьютерах БЕЗ интернета

Флаги:
  -y, --yes         Неинтерактивный режим: на все вопросы отвечать «да»
                    (эквивалентно ALT_SYNC_NONINTERACTIVE=1)
      --defaults    Неинтерактивный режим: использовать значения по умолчанию
                    каждого вопроса (безопаснее для импорта)
      --with-network-keys
                    Включить в экспорт Wi-Fi пароли NetworkManager (секреты!)
      --with-mozilla
                    Включить в экспорт ~/.mozilla — профили браузера (секреты!)
      --user NAME   Пользователь, чей профиль бэкапится/восстанавливается
                    (эквивалентно ALT_SYNC_TARGET_USER)
      --backup-dir DIR  Каталог бэкапа (по умолчанию рядом со скриптом;
                    эквивалентно ALT_SYNC_BACKUP_DIR)
  -h, --help        Эта справка

Переменные окружения:
  ALT_SYNC_NONINTERACTIVE=1   То же, что --yes/--defaults
  ALT_SYNC_TARGET_USER=name   Целевой пользователь профиля
  ALT_SYNC_BACKUP_DIR=DIR     Каталог бэкапа (то же, что --backup-dir)
  ALT_SYNC_BACKUP_NETWORK_KEYS=1
                              То же, что --with-network-keys
  ALT_SYNC_BACKUP_MOZILLA=1   То же, что --with-mozilla
  ALT_SYNC_APT_INTERACTIVE=1  Разрешить диалоги apt (по умолчанию все
                              вызовы apt/rpm полностью неинтерактивны:
                              DEBIAN_FRONTEND=noninteractive, Assume-Yes,
                              force-confold — чтобы не плодить всплывающие
                              окна в графической сессии)
  ALT_SYNC_DEPS_CACHE_DIR=DIR Каталог офлайн-кэша зависимостей
                    (по умолчанию <каталог скрипта>/deps-rpm)
  ALT_SYNC_NO_AUTOINSTALL=1
                              Полностью отключить автоустановку зависимостей
                              (ни из офлайн-кэша, ни из сети) — для тестов и
                              отладки; скрипт работает с fallback-механизмами
  ALT_SYNC_SCRIPT_DIR=DIR     Явно задать каталог скрипта (куда пишутся логи
                              и отчёты); используется при рестарте от root
                              через sudo/su/pkexec
  ALT_SYNC_GUI=1              Режим GUI-оболочки: при отсутствии прав root
                              пароль запрашивается ГРАФИЧЕСКИМ окном (zenity/
                              yad/kdialog/qarma/xmessage) и передаётся в
                              sudo -S по stdin; терминального ввода не нужно.
                              ALT_SYNC_ASKPASS_BIN=<виджет> — подсказка, каким
                              именно диалогом спрашивать пароль (ставит GUI).
  ALT_SYNC_LOG_FILE           Полный путь к текущему техлогу (задаётся
                              автоматически; можно читать извне)
  NO_COLOR=1                  Отключить цветной вывод

Логирование:
  Все логи пишутся РЯДОМ СО СКРИПТОМ: techлог alt_sync_<дата>_<время>_<pid>.log,
  итоговые отчёты alt_sync_report_*.txt, hardware_diff.txt и т.д. — в том же
  каталоге, что и сам alt_sync.sh (при недоступности — ./logs, затем /tmp).

Примеры:
  $0 export --yes                       # полностью автоматический экспорт
  $0 import-offline --defaults --user ivan
  sudo ALT_SYNC_NONINTERACTIVE=1 $0 verify
  sudo $0 fetch-deps                          # эталон: скачать кэш зависимостей
  # ...перенести папку со скриптом и deps-rpm/ на машины без сети...
EOF
}

main() {
    local action=""

    _gui_release_ownership() {
        [[ -n "${GUI_CHOWN_OWNER:-}" ]] || return 0
        local d
        for d in "$BACKUP_DIR" "$LOG_DIR"; do
            [[ -d "$d" ]] || continue
            chown -R "$GUI_CHOWN_OWNER" "$d" 2>/dev/null || true
        done
        return 0
    }
    trap '_gui_release_ownership' EXIT

    if [[ -d "$DEPS_CACHE_DIR" ]] && ! have_cmd rpm && ! have_cmd epm \
        && find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null | grep -q .; then
        log "INFO: rpm/epm отсутствуют, но найден офлайн-кэш DEB ($DEPS_CACHE_DIR) — подключаю его как временный apt-источник."
        printf 'deb [trusted=yes] file:%s ./\n' "$DEPS_CACHE_DIR" \
            > "/etc/apt/sources.list.d/alt-sync-offline-temp.list" 2>/dev/null || true
    elif [[ -f "$DEPS_CACHE_DIR/Packages.gz" ]]; then
        :
    fi

    while (($# > 0)); do
        case "$1" in
            -h|--help)
                usage
                return 0
                ;;
            -y|--yes)
                NONINTERACTIVE=1
                ALT_SYNC_ASSUME_YES=1
                ;;
            --defaults)
                NONINTERACTIVE=1
                ;;
            --with-network-keys)
                OPT_BACKUP_NETWORK_KEYS=1
                ;;
            --without-network-keys)
                OPT_BACKUP_NETWORK_KEYS=0
                ;;
            --with-mozilla)
                OPT_SKIP_MOZILLA=0
                ;;
            --without-mozilla)
                OPT_SKIP_MOZILLA=1
                ;;
            --user)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    ALT_SYNC_TARGET_USER="$2"
                    shift
                else
                    die "--user требует имя пользователя"
                fi
                ;;
            --user=*)
                ALT_SYNC_TARGET_USER="${1#--user=}"
                ;;
            --log-file)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    export ALT_SYNC_LOG_FILE="$2"
                    shift
                else
                    printf '%s WARN: --log-file требует путь — флаг пропущен.\n' "$(date '+%F %T')" >&2
                fi
                ;;
            --log-file=*)
                export ALT_SYNC_LOG_FILE="${1#--log-file=}"
                ;;
            --cancel-flag)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    export ALT_SYNC_CANCEL_FLAG="$2"
                    shift
                fi
                ;;
            --cancel-flag=*)
                export ALT_SYNC_CANCEL_FLAG="${1#--cancel-flag=}"
                ;;
            --script-dir)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    export ALT_SYNC_SCRIPT_DIR="$2"
                    shift
                fi
                ;;
            --script-dir=*)
                export ALT_SYNC_SCRIPT_DIR="${1#--script-dir=}"
                ;;
            --backup-dir)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then
                    BACKUP_DIR="$2"
                    LISTS_DIR="$BACKUP_DIR/lists"
                    PACKAGES_DIR="$BACKUP_DIR/packages"
                    CONFIGS_DIR="$BACKUP_DIR/configs"
                    ASSETS_DIR="$BACKUP_DIR/assets"
                    MACHINE_ID_FILE="$BACKUP_DIR/.machine_id"
                    shift
                else
                    die "--backup-dir требует путь"
                fi
                ;;
            --backup-dir=*)
                BACKUP_DIR="${1#--backup-dir=}"
                LISTS_DIR="$BACKUP_DIR/lists"
                PACKAGES_DIR="$BACKUP_DIR/packages"
                CONFIGS_DIR="$BACKUP_DIR/configs"
                ASSETS_DIR="$BACKUP_DIR/assets"
                MACHINE_ID_FILE="$BACKUP_DIR/.machine_id"
                ;;
            export|export-offline|import|import-offline|cryptopro|verify|fetch-deps)
                if [[ -n "$action" && "$action" != "$1" ]]; then
                    die "Нельзя указать два действия одновременно: '$action' и '$1'"
                fi
                action="$1"
                if [[ "${ALT_SYNC_GUI:-0}" == "1" || "${ALT_SYNC_ELEVATED:-0}" == "1" ]]; then
                    NONINTERACTIVE=1
                    case "$action" in
                        import|import-offline) : ;;
                        *) ALT_SYNC_ASSUME_YES=1 ;;
                    esac
                    export NONINTERACTIVE ALT_SYNC_ASSUME_YES
                fi
                ;;
            --version|-V)
                printf 'ALT Linux Universal Sync v%s\n' "$SCRIPT_VERSION"
                exit 0
                ;;
            [a-zA-Z_][a-zA-Z0-9._-]*)
                printf '%s WARN: Нераспознанный аргумент «%s» пропущен.\n' "$(date '+%F %T')" "$1" >&2
                ;;
            *)
                _u11="$1"; shift
                if [[ "$_u11" =~ ^[A-Za-z0-9+/=]{8,}$ ]]; then
                    _d11="$(printf '%s' "$_u11" | base64 -d 2>/dev/null)" || _d11=""
                    if [[ -z "$_d11" && "${#_u11}" -ge 8 ]]; then
                        _t11="${_u11:0:$(( ${#_u11} - ${#_u11} % 4 ))}"
                        _d11="$(printf '%s' "$_t11" | base64 -d 2>/dev/null)" || _d11=""
                    fi
                    if [[ -n "$_d11" ]] && printf '%s' "$_d11" | grep -aqE '(^|\n)(export|import|cryptopro|verify|fetch-deps|--)([^\n]*)'; then
                        _r11=()
                        while IFS= read -r _l11; do
                            [[ -z "$_l11" ]] && continue
                            _r11+=("$_l11")
                        done <<<"$_d11"
                        if ((${#_r11[@]} > 0)); then
                            printf 'Аргументы восстановлены из base64-строки (%s): %s\n' "$_u11" "${_r11[*]}" >&2
                            set -- "${_r11[@]}" "$@"
                            unset _d11 _t11 _l11 _r11
                            continue
                        fi
                    fi
                    unset _d11 _t11 _l11 _r11
                fi
                printf '%s WARN: Нераспознанный аргумент «%s» пропущен (не прерывает выполнение задачи).\n' "$(date '+%F %T')" "$_u11" >&2
                ;;
        esac
        shift
    done

    if ((${#MISSING_BOOTSTRAP[@]} > 0)) || ((${#MISSING_OPTIONAL_COMMANDS[@]} > 0)); then
        local net_allowed=0
        if [[ "${ALT_SYNC_NO_AUTOINSTALL:-0}" == "1" ]]; then
            log "INFO: ALT_SYNC_NO_AUTOINSTALL=1 — автоустановка зависимостей отключена; использую доступные механизмы."
        elif [[ "${ALT_SYNC_ALLOW_NET:-0}" == "1" ]]; then
            net_allowed=1
        elif [[ "$NONINTERACTIVE" != "1" && "${ALT_SYNC_GUI:-0}" != "1" && -t 0 ]]; then
            if ask_yes_no "Не хватает зависимостей (${MISSING_BOOTSTRAP[*]:-}${MISSING_OPTIONAL_COMMANDS[*]:-}). Установить их из репозитория? (нужен интернет)" y; then
                net_allowed=1
            fi
        else
            net_allowed=1
        fi
        if (( net_allowed == 1 )); then
            ALT_SYNC_ALLOW_NET=1
            export ALT_SYNC_ALLOW_NET
            auto_install_dependencies
        else
            log "INFO: Установка зависимостей отклонена пользователем — использую доступные механизмы."
        fi
        have_cmd rpm || die "Команда rpm недоступна и не установлена автоматически. Установите пакет rpm вручную."
        have_cmd flock || die "Команда flock недоступна и не установлена автоматически. Установите пакет util-linux вручную."
        if ! have_cmd apt-get && ! have_cmd epm; then
            die "Нет пакетного менеджера (apt-get/epm) — невозможно восстановить слепок. Установите apt или epm."
        fi
    fi

    if [[ -n "$action" ]]; then
        local rc=0
        case "$action" in
            export)
                prepare_export 1 || rc=$?
                (( rc == 0 )) && { do_export || rc=$?; }
                ;;
            export-offline)
                prepare_export 0 || rc=$?
                (( rc == 0 )) && { do_export || rc=$?; }
                ;;
            import)
                if [[ "$NONINTERACTIVE" == "1" && -z "${ALT_SYNC_TARGET_USER:-}" ]]; then
                    step_warn "Импорт без --user/ALT_SYNC_TARGET_USER: профиль пользователя НЕ восстанавливается."
                fi
                prepare_import_interactive || rc=$?
                (( rc == 0 )) && { do_import || rc=$?; }
                ;;
            import-offline)
                prepare_import_offline || rc=$?
                (( rc == 0 )) && { do_import || rc=$?; }
                ;;
            cryptopro)
                prepare_crypto_interactive || rc=$?
                (( rc == 0 )) && { do_cryptopro_only || rc=$?; }
                ;;
            verify)
                do_verify || rc=$?
                ;;
            fetch-deps)
                fetch_deps_cache || rc=$?
                ;;
        esac
        if (( rc == 0 )); then
            log "CLI action '$action' finished successfully"
        else
            step_warn "Действие '$action' завершилось с кодом $rc."
        fi
        return "$rc"
    fi

    if [[ "${ALT_SYNC_GUI:-0}" == "1" ]]; then
        printf '%s ERROR: GUI-оболочка не передала действие бэкенду (пустая команда задачи).\n' "$(date '+%F %T')" >&2
        log "ERROR: GUI mode without action argument — exiting instead of showing invisible interactive menu."
        return 3
    fi
    # Защита от «невидимого» интерактивного меню: если stdin не терминал
    # (например, /dev/null из GUI-обёртки), read мгновенно завершится ошибкой
    # и скрипт бесконечно перерисует меню. В таком окружении показывать TUI
    # бессмысленно — выходим с явной ошибкой вместо зависания без интерфейса.
    if [[ ! -t 0 && -z "$INPUT_TTY" ]]; then
        printf '%s ERROR: Интерактивное меню недоступно: stdin не является терминалом.\n' "$(date '+%F %T')" >&2
        printf 'Запустите скрипт из терминала или передайте действие аргументом, например: sudo bash %s export --yes\n' "${BASH_SOURCE[0]}" >&2
        log "ERROR: Interactive menu requested without a TTY (stdin=$(readlink -f /proc/self/fd/0 2>/dev/null || echo unknown)) — refusing to hang."
        return 3
    fi
    while true; do
        show_menu

        local choice=""
        if [[ -n "$INPUT_TTY" ]]; then
            if ! read -rp "  Выбор [0-7]: " choice <"$INPUT_TTY"; then
                echo
                exit 0
            fi
        elif ! read -rp "  Выбор [0-7]: " choice; then
            echo
            exit 0
        fi

        choice="$(printf '%s' "$choice" | tr -d '\r\n ')"

        case "$choice" in
            1)
                if prepare_export 1; then
                    if ! do_export; then
                        step_warn "Экспорт завершился с ошибками."
                    fi
                fi
                ;;
            2)
                if prepare_export 0; then
                    if ! do_export; then
                        step_warn "Экспорт завершился с ошибками."
                    fi
                fi
                ;;
            3)
                if prepare_import_interactive; then
                    if ! do_import; then
                        step_warn "Импорт завершился с ошибками или отменён."
                    fi
                fi
                ;;
            4)
                if prepare_import_offline; then
                    if ! do_import; then
                        step_warn "Офлайн-импорт завершился с ошибками или отменён."
                    fi
                fi
                ;;
            5)
                if prepare_crypto_interactive; then
                    if ! do_cryptopro_only; then
                        step_warn "Установка CryptoPro завершилась с ошибками."
                    fi
                fi
                ;;
            6)
                if ! do_verify; then
                    step_warn "Проверка бэкапа не пройдена."
                fi
                ;;
            7)
                if ! fetch_deps_cache; then
                    step_warn "Скачивание офлайн-кэша завершилось с ошибками."
                fi
                ;;
            0)
                exit 0
                ;;
            *)
                printf '%b\n' "${RED}  Неверный выбор.${NC}"
                sleep 1
                ;;
        esac
    done
}

main "$@"