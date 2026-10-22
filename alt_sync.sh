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

set -euo pipefail

SCRIPT_VERSION="2.0.15-console"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="${BASH_SOURCE[0]}"
if [[ "$SELF" != /* ]]; then
    SELF="$SCRIPT_DIR/$SELF"
fi
# Экранированная версия пути для вложения в «bash -lc "...» внутри Exec= ярлыка:
# двойные кавычки шелла -lc раскроются, и путь с пробелами/спецсимволами
# дойдёт до bash целым аргументом.
printf -v SELF_NO_ESCAPE '%q' "$SELF"

if [[ "$SCRIPT_DIR" == *[[:space:]]* || "$SELF" == *[[:space:]]* ]]; then
    printf 'Путь к скрипту не должен содержать пробелы/табуляцию: %s\n' "$SELF" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    if [[ "${ALT_SYNC_ALLOW_ROOT_RESTART:-1}" == "1" && "${ALT_SYNC_NO_ESCALATE:-0}" != "1" ]]; then
        _as_env=(DEBIAN_FRONTEND=noninteractive "ALT_SYNC_SCRIPT_DIR=$SCRIPT_DIR")
        [[ -n "${ALT_SYNC_NONINTERACTIVE:-}" ]] && _as_env+=("ALT_SYNC_NONINTERACTIVE=$ALT_SYNC_NONINTERACTIVE")
        [[ -n "${ALT_SYNC_ASSUME_YES:-}"   ]] && _as_env+=("ALT_SYNC_ASSUME_YES=$ALT_SYNC_ASSUME_YES")
        [[ -n "${ALT_SYNC_TARGET_USER:-}"  ]] && _as_env+=("ALT_SYNC_TARGET_USER=$ALT_SYNC_TARGET_USER")
        [[ -n "${ALT_SYNC_BACKUP_DIR:-}"   ]] && _as_env+=("ALT_SYNC_BACKUP_DIR=$ALT_SYNC_BACKUP_DIR")
        [[ -n "${ALT_SYNC_BACKUP_NETWORK_KEYS:-}" ]] && _as_env+=("ALT_SYNC_BACKUP_NETWORK_KEYS=$ALT_SYNC_BACKUP_NETWORK_KEYS")
        [[ -n "${ALT_SYNC_BACKUP_MOZILLA:-}" ]] && _as_env+=("ALT_SYNC_BACKUP_MOZILLA=$ALT_SYNC_BACKUP_MOZILLA")
        [[ -n "${ALT_SYNC_ALLOW_NET:-}"    ]] && _as_env+=("ALT_SYNC_ALLOW_NET=$ALT_SYNC_ALLOW_NET")
        [[ -n "${ALT_SYNC_NO_AUTOINSTALL:-}" ]] && _as_env+=("ALT_SYNC_NO_AUTOINSTALL=$ALT_SYNC_NO_AUTOINSTALL")
        _self_q="$(printf '%q' "$SELF")"
        _args_q=""
        for _a in "$@"; do _args_q+=" $(printf '%q' "$_a")"; done
        unset _a
        # Определяем, реально ли доступен sudo этому пользователю:
        # в Astra/ALT обычный пользователь может отсутствовать в sudoers —
        # тогда «sudo» выдаст «astra отсутствует в файле sudoers» и ничего не запустится.
        _sudo_usable=0
        if command -v sudo >/dev/null 2>&1; then
            if sudo -n true 2>/dev/null; then
                _sudo_usable=1
            elif [[ -r /etc/sudoers ]] || grep -qsE '^[[:space:]]*%?(wheel|sudo|adm)\b' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
                # sudoers читается и в нём есть группы администраторов —
                # считаем sudo потенциально рабочим (пользователь может состоять в группе).
                if [[ "$(id -nG 2>/dev/null)" == *" wheel"* || "$(id -nG)" == *"wheel "* || "$(id -nG)" =~ (^| )wheel($| ) || "$(id -nG)" =~ (^| )(sudo|adm)($| ) ]]; then
                    _sudo_usable=1
                fi
            fi
        fi
        if [[ "$_sudo_usable" == "1" ]]; then
            printf 'Для работы нужны права root — перезапускаюсь через sudo (введите пароль при запросе)...\n' >&2
            exec sudo "${_as_env[@]}" bash "$SELF" "$@"
        elif command -v su >/dev/null 2>&1; then
            printf 'Для работы нужны права root — перезапускаюсь через su (введите пароль суперпользователя/root)...\n' >&2
            exec su -c "env ${_as_env[*]} bash $_self_q${_args_q}" root
        elif command -v pkexec >/dev/null 2>&1; then
            printf 'Для работы нужны права root — перезапускаюсь через pkexec (диалог ввода пароля)...\n' >&2
            exec pkexec env "${_as_env[@]}" bash "$SELF" "$@"
        elif command -v sudo >/dev/null 2>&1; then
            # sudo есть, но пользователь, скорее всего, не в sudoers — пробуем, но предупреждаем
            printf 'Для работы нужны права root — перезапускаюсь через sudo...\n' >&2
            printf 'ВНИМАНИЕ: похоже, ваш пользователь не настроен для sudo. Если появится\n' >&2
            printf '«отсутствует в файле sudoers» — запустите вручную: su -c "bash %s"\n' "$SELF" >&2
            exec sudo "${_as_env[@]}" bash "$SELF" "$@"
        else
            printf 'ОШИБКА: требуются права root, но ни sudo, ни pkexec, ни su не найдены.\n' >&2
            printf 'Запустите вручную: su -c "bash %s %s"\n' "$SELF" "$*" >&2
            exit 1
        fi
    elif [[ "${ALT_SYNC_NO_ESCALATE:-0}" == "1" ]]; then
        printf 'WARN: ALT_SYNC_NO_ESCALATE=1 — работаю без повышения прав с uid=%s.\n' "$(id -u)" >&2
    else
        printf 'ОШИБКА: повышение прав отключено (ALT_SYNC_ALLOW_ROOT_RESTART=0), а скрипту нужен root (uid=%s).\n' "$(id -u)" >&2
        printf 'Запустите вручную: sudo bash %s <действие> [флаги]\n' "$SELF" >&2
        exit 78
    fi
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
            printf 'CLI:         %s <export|export-offline|import|import-offline|cryptopro|install-components|verify|fetch-deps|desktop-shortcut> [-y|--yes | --defaults] [--user NAME] [--backup-dir DIR]\n' "$SELF"
            printf 'Env:         ALT_SYNC_NONINTERACTIVE=1, ALT_SYNC_TARGET_USER=name, ALT_SYNC_BACKUP_DIR=DIR, NO_COLOR=1\n'
            printf 'Логи:        рядом со скриптом (%s); при недоступности — ./logs, затем /tmp\n' "$(dirname "$SELF")"
            printf '(Полная справка — в интерактивном/CLI-режиме от root.)\n'
            exit 0
            ;;
    esac
done
unset _pre_arg

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

# v2.0.7: режим «умной» установки — по умолчанию пропускаем уже установленные
# пакеты (той же или более новой версии) и ставим только недостающие/обновляемые.
# Отключается флагом --force-reinstall или ALT_SYNC_FORCE_REINSTALL=1.
OPT_SKIP_INSTALLED=1
if [[ "${ALT_SYNC_FORCE_REINSTALL:-0}" == "1" ]]; then
    OPT_SKIP_INSTALLED=0
fi

declare -A INSTALLED_VER_MAP=()

# Кэш результатов rpm_ver_ge для групповой установки (одна и та же пара
# версий встречается многократно при импорте больших списков).
declare -A VER_GE_CACHE=()

rpm_ver_ge_cached() {
    local key="$1|$2" r
    if [[ -n "${VER_GE_CACHE[$key]+x}" ]]; then
        [[ "${VER_GE_CACHE[$key]}" == "1" ]] && return 0 || return 1
    fi
    if rpm_ver_ge "$1" "$2"; then
        r=0
    else
        r=1
    fi
    VER_GE_CACHE["$key"]=$r
    (( r == 0 ))
}

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
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
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
_as_log_beacons() { return 0; }
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

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"
    if command -v sync >/dev/null 2>&1; then
        case "$*" in
            PROGRESS\|*|STEP\ *|INIT:*|FATAL:*|ERROR:*) sync ;;
        esac
    fi
}

log "INIT: alt_sync v$SCRIPT_VERSION запущен (pid=$$, uid=$(id -u), лог=$LOG_FILE)"

# ─── Определение терминала ввода/вывода ──────────────────────────────────────
# ВАЖНО (v2.0.5): при запуске через ярлык вида
#   konsole -e bash -lc "su -c 'bash alt_sync.sh'"
# su ПЕРЕКРЫВАЕТ свой управляющий запрос пароля на /dev/tty (как makebase в
# util-linux), и после ввода пароля read с /dev/tty возвращает EIO
# («read: ошибка чтения: 0: Ошибка ввода/вывода») — меню мгновенно гибнет,
# окно «висит», а логи продолжают писаться. Поэтому:
#   1) если stdin является терминалом (-t 0) — читаем ВВОД из stdin: именно
#      его су/терминал гарантирует нам после завершения своей работы;
#   2) только если stdin НЕ терминал, пробуем /dev/tty;
#   3) дублирование ВЫВОДА в лог делаем БЕЗ process substitution и без
#      переназначения fd 3 (см. ниже) — раньше это ломало терминальный вывод.
INPUT_TTY=""
INTERACTIVE=0
if [[ -t 0 ]]; then
    INTERACTIVE=1
elif [[ -r /dev/tty ]] && [[ -w /dev/tty ]]; then
    INTERACTIVE=1
    INPUT_TTY="/dev/tty"
fi

# Функция чтения пользовательского ввода: корректно работает и при
# «stdin = TTY», и при «только /dev/tty доступен», и в неинтерактивном режиме.
# Возвращает 0 при успешном чтении строки (строка — в переменной REPLY_OUT),
# 1 при EOF/ошибке чтения.
# ВАЖНО: read вызывается ВНУТРИ функции без редиректа, когда stdin уже
# перенаправлен на терминал — так read получает tty напрямую (и readline, и
# сигналы работают штатно).
read_user_input() {
    local __prompt="${1:-}"
    REPLY_OUT=""
    if [[ "$NONINTERACTIVE" == "1" || "$INTERACTIVE" != "1" ]]; then
        return 1
    fi
    # v2.0.6: промпт печатаем ЧЕРЕЗ STDOUT (printf), а не read -p.
    # Причина: bash пишет «read -p»-промпт в stderr только когда stdin — TTY
    # И stdout тоже TTY; при обёртках (su/konsole/ssh) это условие иногда
    # нарушается и приглашение молча исчезает («окно висит, логи пишутся»).
    # printf виден всегда; вывод идёт через тот же канал, что и меню.
    [[ -n "$__prompt" ]] && printf '%s' "$__prompt"
    if [[ -n "$INPUT_TTY" ]]; then
        # stdin не терминал — читаем из /dev/tty редиректом
        IFS= read -r REPLY_OUT <"$INPUT_TTY" || return 1
    else
        # stdin — терминал: read без редиректа читает прямо с tty
        IFS= read -r REPLY_OUT || return 1
    fi
    return 0
}

# ЛОГИРОВАНИЕ ВЫВОДА (v2.0.5-fix, финальная схема): интерактивный вывод идёт
# НАПРЯМУЮ в унаследованный TTY — stdout/stderr НЕ перехватываются вообще
# (ни «exec > >(sed|tee)», ни конвейером вокруг перезапускаемого себя). Оба
# прежних способа ломали терминал: process substitution конфликтовала с
# чтением (read → EIO), а pipe+tee буферизовал весь экран («окно висит, логи
# пишутся»). В журнале $LOG_FILE надёжно остаются все служебные записи log()
# (INIT/STEP/INFO/WARN/ERROR/FATAL) — они пишутся сюда напрямую; пользователь-
# ский экранный вывод в TTY не дублируется. Неинтерактивный запуск (без TTY)
# пишет весь stdout/stderr только в лог — см. «Точку входа» в конце файла.

export -n INPUT_TTY 2>/dev/null || true

_finish_log() {
    local rc=$?
    printf '%s INFO: Завершение работы (exit code %s)\n' "$(date '+%F %T')" "$rc" >> "$LOG_FILE" 2>/dev/null || true
}
trap _finish_log EXIT

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
    printf '%b\n' "  ${CYAN}▓▓▓ Прогресс: ${BOLD}${_spct}%${NC} (шаг ${CURRENT_STEP} из ${TOTAL_STEPS}, время $(elapsed_string))${NC}"
    log "PROGRESS pct=$_spct step=$CURRENT_STEP/$TOTAL_STEPS :: $1"
}

CANCELLED_BY_USER=0
_on_interrupt() {
    CANCELLED_BY_USER=1
    printf '

%s
' "⏹  Получен сигнал прерывания (Ctrl+C). Задача будет корректно остановлена на ближайшей контрольной точке…" >&2
    log "CANCEL: получен SIGINT/SIGTERM (pid=$$)"
}
trap _on_interrupt INT TERM

gui_cancel_check() {
    (( CANCELLED_BY_USER )) || return 0
    log "CANCEL: задача прервана пользователем (Ctrl+C) (${1:-})"
    printf '\n%s\n' "⛔ Отменено пользователем (${1:-}). Выполняется откат временных данных…"
    exit 130
}

# Возвращает 0, если пользователь нажал Ctrl+C (используется в progress_bar
# как контрольная точка отмены). Раньше эта функция вызывалась, но нигде не
# была определена — при первом же вызове progress_bar скрипт падал с
# «command not found» под set -e.
gui_cancel_requested() {
    (( CANCELLED_BY_USER ))
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

    # ВАЖНО (v2.0.5): интерактивность определяется через INTERACTIVE
    # («stdin = TTY» ИЛИ доступен /dev/tty) — см. начало файла. Прежняя
    # проверка «-z "$INPUT_TTY"» при stdin=TTY была ложной и уходила в
    # автоответ; обратный случай (su перекрывает /dev/tty своим запросом
    # пароля → EIO) лечится тем, что читаем из stdin, а не из /dev/tty.
    if [[ "$NONINTERACTIVE" == "1" ]] || [[ "$INTERACTIVE" != "1" ]]; then
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

    local rc=0 ans_is_eof=0 ans=""
    if ! read_user_input ""; then
        rc=$?
        printf '\n'
        if (( rc > 1 )); then
            ans="$def"
            ans_is_eof=1
        fi
    else
        ans="$REPLY_OUT"
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
            if (( ans_is_eof == 0 )); then
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

    # «&& gui_cancel_check ...» под set -e опасен: когда отмены нет,
    # gui_cancel_requested возвращает 1 и составная команда завершается с
    # ошибкой. Используем явный if — безопасно при любом раскладе.
    if gui_cancel_requested; then
        gui_cancel_check "во время: $label"
    fi

    if (( pct != LAST_PROGRESS_PCT )); then
        log "$label $current/$total (${pct}%)"
        local _lbl="$label"
        [[ -n "$item" ]] && _lbl="$label [$item]"
        log "PROGRESS detail pct=$pct ($_lbl)"
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


TARGET_USER=""
HOME_DIR=""
TARGET_GROUP=""

have_cmd() { command -v "$1" >/dev/null 2>&1; }

REQUIRED_CORE_UTILS=(find sort tar awk sed grep date getent sleep wc cut tr
                     dirname basename mkdir rm cp chmod touch cat xargs id
                     mktemp hostname uname du mv sha256sum)

# Формат записи: команда|кандидаты-пакеты (первый найденный в репозиториях используется).
# ВАЖНО (v2.0.9): имена пакетов различаются между ветками ALT (p10/p11) и другими
# дистрибутивами, поэтому вместо одного жёсткого имени указан список кандидатов,
# а перед установкой каждый кандидат проверяется через доступность в индексах apt
# (см. resolve_pkg_candidate). Например: xz-utils существует только в Sisyphus,
# в p10/p11 пакет называется xz; polkit в ALT — libpolkit или polkit-demo-utils.
DEPENDENCY_SPECS=(
    "rpm|rpm"
    "apt-get|apt apt"
    "flock|util-linux util-linux-core"
    "gzip|gzip"
    "bzip2|bzip2"
    "xz|xz xz-utils"
    "zstd|zstd libzstd"
    "timeout|coreutils timeout"
    "unrar|unrar unrar-nonfree"
    "unar|unar"
    "bsdtar|libarchive-tools libarchive bsd-tar"
    # v2.0.15: в ALT Linux пакета «p7zip» нет — 7z/7za поставляет пакет 7-zip
    # (подтверждено практикой: apt-get install p7zip-full -> E: Невозможно найти
    # пакет p7zip-full; виртуальное имя p7zip резолвится в 7-zip).
    "7z|7-zip p7zip p7zip-full"
    "7za|7-zip p7zip p7zip-full"
    "unzip|unzip"
    "epm|eepm epm"
    # ВАЖНО (v2.0.14): подтверждено практикой — libnewt/libnewt52 содержат ТОЛЬКО
    # разделяемую библиотеку libnewt.so и НЕ ставят /usr/bin/whiptail
    # («Последняя версия libnewt52 уже установлена», а whiptail так и нет).
    # Исполняемый whiptail в ALT Linux p10/p11 входит в бинарный пакет newt52
    # (исходный пакет называется newt — такого бинарного пакета нет).
    # Порядок кандидатов: сначала пакеты с самим исполняемым файлом, затем
    # библиотеки как резервный канал зависимостей.
    #   1) newt52           — пакет с /usr/bin/whiptail (правильное имя в p11);
    #   2) newt-preinstall  — альтернативная упаковка whiptail (сторонние репо);
    #   3) whiptail         — на случай репозиториев с выделенным пакетом;
    #   4) libnewt libnewt52 — только библиотека; ставятся последними, и после их
    #       установки скрипт проверяет наличие команды (см. install_cmd_by_candidates).
    "whiptail|newt52 newt-preinstall whiptail libnewt libnewt52"
    "dialog|dialog CD-ROM-dialog"
    "pkexec|polkit polkit-askpass-server libpolkit"
)

# Разворачивает «cmd|pkg1 pkg2 ...» в массив кандидатов
spec_candidates() {
    local spec="$1"
    read -ra __CANDIDATES <<< "${spec#*|}"
}

pkg_for_cmd() {
    local spec c
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"
        if [[ "$c" == "$1" ]]; then
            spec_candidates "$spec"
            printf '%s' "${__CANDIDATES[0]}"
            return 0
        fi
    done
    printf '%s' "$1"
}

# v2.0.15: проверка доступности пакета (в т.ч. виртуального имени) через
# симуляцию apt-get install -s без сети. Возвращает 0, если apt собрался
# установить/обновить пакет или он уже установлен последней версией.
simulate_apt_install_ok() {
    local p="$1" out rc
    [[ -z "$p" || "$p" == *" "* ]] && return 1
    have_cmd apt-get || return 1
    # ВНИМАНИЕ: «0 будет обновлено» содержит подстроку «будет обновлено», но
    # означает отсутствие изменений — поэтому проверяем НОВЫЕ/обновление явно.
    out="$(apt_with_timeout 60 env DEBIAN_FRONTEND=noninteractive \
            apt-get -s install -y --no-install-recommends "$p" </dev/null 2>/dev/null)" && rc=0 || rc=$?
    (( rc == 0 )) || return 1
    grep -qE 'НОВЫЕ пакеты будут установлены|будут установлены' <<<"$out" && return 0
    grep -qE '[1-9][0-9]* будет обновлено' <<<"$out" && return 0
    grep -qE 'уже установлена' <<<"$out" && return 0
    return 1
}

# v2.0.15: разворачивает имя пакета (в т.ч. виртуальное ALT-имя вроде xz/p7zip/
# eepm/libpolkit) в список реальных бинарных имён пакетов. Использует вывод
# apt-cache show и симуляцию apt-get -s install (локализация ru/en). Пустой
# вывод + код 1 — не удалось; тогда возвращается исходное имя как есть.
pkg_to_bin_nvras() {
    local p="$1" line name out="" seen=" "
    [[ -z "$p" || "$p" == *" "* ]] && return 1
    have_cmd apt-get || { printf '%s' "$p"; return 0; }
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"     # trim leading spaces
        case "$line" in
            Package:*|Пакет:*) name="${line#*:}" ;;
            *) continue ;;
        esac
        name="${name#"${name%%[![:space:]]*}"}"     # trim
        name="${name%% *}"
        [[ -z "$name" ]] && continue
        [[ "$name" == *-devel* || "$name" == *-debug* || "$name" == *-doc* ]] && continue
        [[ "$seen" == *" $name "* ]] && continue
        seen+=" $name "
        out+="$name "
    done < <( apt-cache show "$p" 2>/dev/null | sed -n 's/^Package:[[:space:]]*//p; s/^Пакет:[[:space:]]*//p' )
    if [[ -n "$out" ]]; then printf '%s' "${out% }"; return 0; fi
    # не резолвится через show (виртуальное имя) — оставляем исходное имя:
    # apt-get download/install сами умеют разворачивать виртуальные имена.
    printf '%s' "$p"
    return 1
}

# Возвращает 0 и печатает имя пакета, который реально доступен для установки
# (уже установлен ИЛИ найден хотя бы в одном включённом репозитории).
resolve_pkg_candidate() {
    local candidates=("$@") p
    # уже установлен?
    for p in "${candidates[@]}"; do
        if have_cmd rpm && rpm -q "$p" >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
    done
    # есть ли такой пакет в индексах apt?
    if have_cmd apt-cache; then
        for p in "${candidates[@]}"; do
            if apt-cache show "$p" >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
        done
    fi
    # v2.0.15: виртуальные имена ALT (libpolkit, apt, rpm, libarchive и т.п.)
    # apt-cache show НЕ резолвит сам — они видны только через «apt-get -s install».
    # Поэтому дополнительно пробуем симуляцию установки для каждого кандидата.
    if have_cmd apt-get; then
        for p in "${candidates[@]}"; do
            if simulate_apt_install_ok "$p"; then printf '%s' "$p"; return 0; fi
        done
    fi
    # v2.0.15: если apt-cache show не резолвит имя (виртуальные имена вроде xz,
    # p7zip, eepm могут отсутствовать как Package:) — пробуем epm-query ниже,
    # а финальную проверку доступности делает pkg_to_bin_nvras/simulate на этапе
    # скачивания (см. fetch_deps_cache). Здесь — только быстрые проверки.
    if have_cmd epm; then
        for p in "${candidates[@]}"; do
            if epm --no-prompt query "$p" >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
        done
    fi
    # ничего не нашли — возвращаем первый кандидат (штатная попытка установки)
    printf '%s' "${candidates[0]}"
    return 1
}

# То же, но по команде: находит спековую запись и резолвит её кандидатов
resolve_pkg_for_cmd() {
    local want="$1" spec c
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"
        if [[ "$c" == "$want" ]]; then
            spec_candidates "$spec"
            resolve_pkg_candidate "${__CANDIDATES[@]}"
            return $?
        fi
    done
    printf '%s' "$want"
    return 1
}

# v2.0.13: установка недостающей КОМАНДЫ с полным перебором кандидатов.
# Раньше, если первый доступный кандидат (например, виртуальное имя libnewt)
# не резолвился apt-get в конкретный бинарный пакет и установка падала,
# скрипт прекращал попытки, хотя следующий кандидат (libnewt52) гарантированно
# устанавливался. Теперь кандидаты, найденные в индексах, пробуются по одному
# до первого успеха; при полном неудачном исходе возвращается 1.
# v2.0.14: добавлена финальная проверка «команда реально появилась» (have_cmd).
# Практика показала: apt может рапортовать успех установки библиотеки
# (libnewt/libnewt52 — «Последняя версия уже установлена»), но /usr/bin/whiptail
# при этом отсутствует, т.к. исполняемый файл лежит в пакете newt52. Теперь
# «успешной» считается только установка, после которой команда доступна;
# иначе перебор кандидатов продолжается.
install_cmd_by_candidates() {
    local want="$1" spec c cand found rc=1 tried=""
    have_cmd "$want" && return 0
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"
        [[ "$c" == "$want" ]] || continue
        spec_candidates "$spec"
        # Сначала пробуем «умного» победителя (первого доступного в индексах)...
        found="$(resolve_pkg_candidate "${__CANDIDATES[@]}")"; rc=$?
        if (( rc == 0 )); then
            if install_pkg_by_name "$found"; then
                if have_cmd "$want"; then
                    log "INFO: установлен пакет $found (команда: $want)."
                    return 0
                fi
                warn "Пакет '$found' установлен, но команда '$want' по-прежнему недоступна — пробую следующего кандидата."
            fi
            tried+=" $found"
        fi
        # ...затем ВСЕ остальные кандидаты по одному (пропускаем уже пробованные).
        for cand in "${__CANDIDATES[@]}"; do
            [[ "$cand" == "$found" ]] && continue
            [[ " $tried " == *" $cand "* ]] && continue
            if install_pkg_by_name "$cand"; then
                if have_cmd "$want"; then
                    log "INFO: установлен пакет $cand (команда: $want)."
                    return 0
                fi
                # Кандидат установился, но бинарника нет (типично для библиотек
                # libnewt52) — НЕ считаем это успехом, идём дальше.
                warn "Пакет '$cand' установлен, но команда '$want' по-прежнему недоступна — пробую следующего кандидата."
            fi
            tried+=" $cand"
        done
    done
    return 1
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
# ВАЖНО (v2.0.5): rpm/apt-get НЕ являются bootstrap-зависимостями — без них
# меню, сводка системы, проверка бэкапа и ярлыки работают. Действия, которым
# нужны пакетные инструменты (экспорт/импорт/CryptoPro), проверяют это сами
# через require_pkg_tools() в момент запуска и дают понятную ошибку. Раньше
# их отсутствие поднимало диалог автоустановки до показа меню.
MISSING_BOOTSTRAP=()
unset _cmd

OPTIONAL_COMMANDS=(rpm apt-get gzip bzip2 xz zstd timeout unrar unar bsdtar 7z 7za unzip epm whiptail systemctl ldconfig udevadm)
MISSING_OPTIONAL_COMMANDS=()
for _cmd in "${OPTIONAL_COMMANDS[@]}"; do
    if ! have_cmd "$_cmd"; then
        MISSING_OPTIONAL_COMMANDS+=("$_cmd")
    fi
done
unset _cmd

__arch_found=0
for _a in 7z 7za unar bsdtar unrar; do have_cmd "$_a" && { __arch_found=1; break; }; done
if (( __arch_found )); then
    __kept=()
    for _cmd in "${MISSING_OPTIONAL_COMMANDS[@]}"; do
        case "$_cmd" in 7z|7za|unar|bsdtar|unrar) ;; *) __kept+=("$_cmd") ;; esac
    done
    # Если после фильтра список пуст, присваивание с «:-» создавало бы один
    # пустой элемент — тогда ${#...} = 1 и скрипт ложно считал бы, что чего-то
    # не хватает. Присваиваем только непустой массив.
    if ((${#__kept[@]} > 0)); then
        MISSING_OPTIONAL_COMMANDS=("${__kept[@]}")
    else
        MISSING_OPTIONAL_COMMANDS=()
    fi
    unset __kept
fi
unset __arch_found _a

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

# v2.0.5-fix: замок наследуется дочернему процессу log-конвейера через fd 9 →
# повторный flock -n в дочке всегда падал с «Другой экземпляр уже запущен».
# Если fd 9 уже открыт на этот же файл замка (наследник родительского
# экземпляра) — блокировка унаследована, повторно захватывать не нужно.
_as_lock_is_fd9() {
    local __t
    __t="$(readlink -f /proc/self/fd/9 2>/dev/null)" || return 1
    [[ -n "$__t" && "$__t" == "$(readlink -f "$LOCK_FILE" 2>/dev/null || echo "$LOCK_FILE")" ]]
}

if _as_lock_is_fd9; then
    log "INFO: Замок унаследован от родительского процесса (fd 9 = $LOCK_FILE) — повторный захват пропущен."
elif (( HAVE_FLOCK == 1 )); then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Другой экземпляр alt_sync уже запущен (замок: $LOCK_FILE). Дождитесь его завершения."
else
    exec 9>"$LOCK_FILE"
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
    # ВАЖНО (v2.0.14): в ALT Linux p11 исполняемый whiptail (нужен интерактиву
    # epm play pantum) входит в пакет newt52; libnewt/libnewt52 — только
    # библиотека, сами по себе команду не дают.
    newt52
    libnewt
    # Критично для «epm play pantum»: драйвер Pantum распространяется в виде
    # .deb, и eepm конвертирует его через dpkg-deb + alien. Без этих пакетов
    # на чистой копии epm play падает с «dpkg-deb: команда не найдена».
    dpkg
    alien
    p7zip
    wget
    cpio
    rpm-build
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
    # v2.0.12: переписано с «списка имён пакетов» на «список недостающих КОМАНД».
    # Раньше в message/log попадала вся строка кандидатов целиком («newt whiptail
    # libnewt»), и её пытались резолвить как одно имя пакета — отсюда ложное
    # «не найдено ни в одном репозитории». Теперь для каждой недостающей команды
    # кандидаты (реальные имена пакетов ALT) перебираются по одному.
    local -a missing_cmds=()
    local spec c
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"
        have_cmd "$c" || missing_cmds+=("$c")
    done
    ((${#missing_cmds[@]} == 0)) && { log "INFO: Все зависимости на месте."; return 0; }
    info "Не хватает зависимостей (${#missing_cmds[@]}): ${missing_cmds[*]}. Пробую установить автоматически..."
    set +e
    # ВАЖНО (v2.0.9): обновляем индексы репозиториев ДО резолвинга кандидатов.
    # Без этого apt-cache работает по устаревшему локальному кэшу списков и
    # ложно сообщает «пакет не найден в репозиториях» при первом запуске.
    refresh_repo_indexes_once

    # Сначала — офлайн-кэш (по командам: внутри он сам разворачивает кандидатов)
    if deps_cache_available; then
        info "Пробую установить недостающие зависимости из офлайн-кэша: $DEPS_CACHE_DIR"
        install_pkgs_from_offline_cache "${missing_cmds[@]}" || true
    fi

    local ok=0 fail=0 resolved rc
    local -a skipped=()
    for c in "${missing_cmds[@]}"; do
        have_cmd "$c" && { ok=$((ok+1)); continue; }   # уже поставился из кэша
        # Резолвим имя пакета среди кандидатов спеки команды: берём тот, который
        # реально есть в rpm/apt-cache/epm. Если ни один кандидат не найден —
        # пропускаем с понятным сообщением вместо бесконечных неудачных попыток.
        resolved="$(resolve_pkg_for_cmd "$c")"; rc=$?
        if (( rc != 0 )); then
            spec_candidates_for_display=""
            for spec in "${DEPENDENCY_SPECS[@]}"; do
                [[ "${spec%%|*}" == "$c" ]] && spec_candidates_for_display="${spec#*|}"
            done
            warn "Для команды '$c' не найден ни один устанавливаемый пакет в реестре ни в одном включённом репозитории (проверены кандидаты: ${spec_candidates_for_display:-$c}). Пропускаю — будет использован fallback."
            skipped+=("$c")
            continue
        fi
        if install_cmd_by_candidates "$c"; then
            ok=$((ok+1))
        else
            fail=$((fail+1)); warn "Не удалось установить пакет: $resolved (команда: $c)"
        fi
    done
    ((${#skipped[@]} > 0)) && log "INFO: пропущены недоступные зависимости: ${skipped[*]} (скрипт продолжит работу через fallback-механизмы)."
    log "INFO: автоустановка зависимостей: успех=$ok, ошибок=$fail."
    set -e
}

# Возвращает список всех команд, для которых указан пакет $1
pkg_to_cmds() {
    local want="$1" spec c p
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        [[ " $p " == *" $want "* ]] && printf '%s\n' "$c"
    done
}

pkg_for_cmd_reverse() {
    local cmds
    cmds="$(pkg_to_cmds "$1")"
    if [[ -n "$cmds" ]]; then printf '%s' "$(printf '%s\n' "$cmds" | head -1)"; else printf '%s' "$1"; fi
}

# Подбирает доступный кандидат-пакет по имени из спеки (возвращает первое
# доступное имя среди всех кандидатов всех спек, где встречается это имя,
# либо само имя, если оно доступно напрямую)
resolve_pkg_candidate_by_pkgname() {
    local want="$1" spec c p cand found rc=1
    # собираем уникальных кандидатов из всех спек, содержащих want
    local -A seen=(); local -a cands=()
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        p="${spec#*|}"
        [[ " $p " == *" $want "* ]] || continue
        read -ra _cs <<< "$p"
        for cand in "${_cs[@]}"; do
            [[ -n "${seen[$cand]:-}" ]] && continue
            seen["$cand"]=1; cands+=("$cand")
        done
    done
    ((${#cands[@]} == 0)) && cands=("$want")
    found="$(resolve_pkg_candidate "${cands[@]}")"; rc=$?
    printf '%s' "$found"
    return "$rc"
}

candidates_for_pkgname() {
    local want="$1" spec p out=""
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        p="${spec#*|}"
        [[ " $p " == *" $want "* ]] && out+=" $p"
    done
    [[ -z "$out" ]] && out=" $want"
    printf '%s' "${out# }"
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
        # v2.0.12: аргументы могут быть ИМЕНАМИ КОМАНД (whiptail, bsdtar) —
        # разворачиваем их в кандидатов через DEPENDENCY_SPECS; если это уже
        # имя пакета (libnewt и т.п.), оно остаётся в списке как есть.
        if [[ -n "$(pkg_to_cmds "$p")" ]]; then
            p="$(pkg_for_cmd "$p")"
        fi
        # Собираем полный список кандидатов (xz вместо xz-utils и т.п.).
        local -a pcands=("$p")
        read -ra _tmpc <<< "$(candidates_for_pkgname "$p")" 2>/dev/null || true
        for _tc in "${_tmpc[@]}"; do [[ " ${pcands[*]} " == *" $_tc "* ]] || pcands+=("$_tc"); done
        # Пробуем установить каждого кандидата по одному имени (apt не знает
        # про «или» — раньше вся строка кандидатов целиком передавалась как
        # одно имя пакета и гарантированно падала).
        local _pc_installed=""
        for _tc in "${pcands[@]}"; do
            if (( APT_LOCAL_ENABLED == 1 )) && apt_install_local "$_tc"; then
                log "INFO: пакет $_tc установлен из офлайн-кэша ($DEPS_CACHE_DIR)."
                _pc_installed="$_tc"; break
            fi
        done
        [[ -n "$_pc_installed" ]] && continue
        if (( have_rpm )) && have_cmd rpm; then
            rpm -Uhv --replacepkgs --nodeps "$DEPS_CACHE_DIR"/*.rpm </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
        fi
        if (( have_deb )) && command -v dpkg >/dev/null 2>&1; then
            for _tc in "${pcands[@]}"; do
                local debf
                for debf in "$DEPS_CACHE_DIR"/"${_tc}"_*.deb "$DEPS_CACHE_DIR"/"${_tc}"-*.deb "$DEPS_CACHE_DIR"/"${_tc}".deb; do
                    [[ -f "$debf" ]] || continue
                    env DEBIAN_FRONTEND=noninteractive dpkg -i --force-depends "$debf" </dev/null >>"${LOG_FILE:-/dev/null}" 2>&1 || true
                done
            done
        fi
        # Проверка «получен ли пакет»: команда доступна ИЛИ файл любого кандидата
        # лежит в кэше (для последующей сетевой доводки зависимостей).
        c="$(pkg_for_cmd_reverse "$p")"
        if have_cmd "$c"; then
            log "INFO: пакет $p получен из офлайн-кэша."
            continue
        fi
        local _pc _found_in_cache=0
        for _pc in "${pcands[@]}"; do
            if find "$DEPS_CACHE_DIR" -maxdepth 1 -type f \( -iname "${_pc}-*.rpm" -o -iname "${_pc}_*.deb" \) -print -quit 2>/dev/null | grep -q .; then
                _found_in_cache=1; break
            fi
        done
        if (( _found_in_cache == 1 )); then
            log "INFO: пакет $p (или кандидат из $_pc) присутствует в офлайн-кэше."
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

    # ВАЖНО (v2.0.9): для каждой зависимости перебираем ВСЕ кандидаты из спеки и
    # скачиваем первого доступного в репозиториях. Раньше использовалось одно
    # жёсткое имя (например, xz-utils/polkit/dialog), которого нет в p10/p11 ALT,
    # и пакет ложно помечался как «недоступен в репозиториях».
    local -A seen=(); local -a pkgs=() resolved_pkgs=() spec c p rc
    for spec in "${DEPENDENCY_SPECS[@]}"; do
        c="${spec%%|*}"; p="${spec#*|}"
        [[ -n "${seen[$p]:-}" ]] && continue
        seen["$p"]=1; pkgs+=("$p")
    done

    local tmp total=${#pkgs[@]} done_n=0 failed=() notavail=()
    # Резолвим кандидатов ДО проверки доступности
    for ((i = 0; i < total; i++)); do
        resolved="$(resolve_pkg_candidate_by_pkgname "${pkgs[$i]}")"; rc=$?
        if (( rc == 0 )); then
            resolved_pkgs+=("$resolved")
        else
            resolved_pkgs+=("${pkgs[$i]}")   # оставим — ниже будет отфильтрован
        fi
    done
    pkgs=("${resolved_pkgs[@]}")
    # уникализация (несколько команд могут резолвиться в один пакет)
    local -A useen=(); local -a upkgs=()
    for p in "${pkgs[@]}"; do
        [[ -n "${useen[$p]:-}" ]] && continue
        useen["$p"]=1; upkgs+=("$p")
    done
    pkgs=("${upkgs[@]}"); total=${#pkgs[@]}

    if have_cmd apt-get; then
        local _pol
        for ((i = total - 1; i >= 0; i--)); do
            # v2.0.12: если элемент всё ещё содержит пробелы (ни один кандидат не
            # был доступен по отдельности) — это список-спека, а не имя пакета;
            # apt-cache policy по нему работать не может.
            [[ "${pkgs[$i]}" == *" "* ]] && { notavail+=("${pkgs[$i]}"); unset 'pkgs[i]'; pkgs=("${pkgs[@]}"); continue; }
            # v2.0.15: доступность = есть в apt-cache policy ИЛИ резолвится через
            # apt-cache show/симуляцию установки (виртуальные имена ALT).
            _pol=$(apt-cache policy "${pkgs[$i]}" 2>/dev/null | grep -cE '^\s+[0-9]+:') || _pol=0
            if (( _pol == 0 )) && ! simulate_apt_install_ok "${pkgs[$i]}"; then
                notavail+=("${pkgs[$i]}")
                unset 'pkgs[i]'
                pkgs=("${pkgs[@]}")
            fi
        done
    elif have_cmd epm; then
        local _e
        for ((i = total - 1; i >= 0; i--)); do
            [[ "${pkgs[$i]}" == *" "* ]] && { notavail+=("${pkgs[$i]}"); unset 'pkgs[i]'; pkgs=("${pkgs[@]}"); continue; }
            if ! epm --no-prompt query "${pkgs[$i]}" >/dev/null 2>&1; then
                notavail+=("${pkgs[$i]}")
                unset 'pkgs[i]'
                pkgs=("${pkgs[@]}")
            fi
        done
    fi
    ((${#notavail[@]} > 0)) && log "INFO: пропущены недоступные в репозиториях пакеты (все кандидаты исчерпаны): ${notavail[*]}"

    # v2.0.15: если ни один кандидат спеки не разрешился (резолвер вернул список
    # через пробел или первое имя), перебираем ВСЕ имена кандидатов по одному и
    # оставляем только реально доступные (например, для whiptail: newt52, а не
    # несуществующий «whiptail»).
    local -a exp=()
    for p in "${pkgs[@]}"; do
        if [[ "$p" == *" "* ]]; then
            read -ra _xc <<< "$p"
            for _x in "${_xc[@]}"; do
                have_cmd rpm && rpm -q "$_x" >/dev/null 2>&1 && { exp+=("$_x"); continue; }
                apt-cache show "$_x" >/dev/null 2>&1 && exp+=("$_x")
            done
        else
            exp+=("$p")
        fi
    done
    pkgs=("${exp[@]}"); total=${#pkgs[@]}

    # v2.0.15: «apt download» работает ТОЛЬКО с реальными бинарными NVRA-именами
    # (например, 7-zip-25.01-alt1.x86_64). Виртуальные имена ALT (xz -> xz-file/
    # xz-python3, p7zip -> 7-zip, eepm и т.п.) он не умеет и падает с ошибкой по
    # всей пачке — из-за этого deps-rpm/ оставался пустым даже при исправном
    # интернете. Разворачиваем каждое имя в список конкретных NVRA через
    # apt-cache show / симуляцию apt-get -s install.
    local -a dl_pkgs=()
    for p in "${pkgs[@]}"; do
        local _nvras
        _nvras="$(pkg_to_bin_nvras "$p")"
        if [[ -n "$_nvras" && "$_nvras" != *$'\n'* ]]; then
            read -ra _ns <<< "$_nvras"
            for _n in "${_ns[@]}"; do dl_pkgs+=("$_n"); done
        else
            dl_pkgs+=("$p")
        fi
    done
    pkgs=("${dl_pkgs[@]}"); total=${#pkgs[@]}

    if (( total == 0 )); then
        step_warn "Все проверяемые пакеты уже установлены или недоступны — скачивать нечего."
        return 0
    fi
    # v2.0.15: раньше качался только ОТСУТСТВУЮЩИЙ набор кандидатов, а пакеты,
    # уже установленные на эталоне (xz, gzip, util-linux, apt, rpm, dialog...),
    # в кэш НЕ попадали — на офлайн-клиентах их было нечем ставить, и папка
    # deps-rpm/ оставалась пустой. Теперь в кэш скачиваются ВСЕ резолвящиеся
    # зависимости (в т.ч. уже установленные) + транзитивные зависимости через
    # резервный канал install --download-only.
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-fetch.XXXXXX")" || die "mktemp не удался"
    add_cleanup_tmpdir "$tmp"

    local f copied=0 ok_dl=0 fail_dl=()
    local i j _dlcached
    # v2.0.15: качаем пачками по 12 имён одним вызовом (быстрее), при неудаче
    # пачки повторяем поштучно — один сбойный пакет не блокирует остальные.
    for ((i = 0; i < total; i += 12)); do
        local -a batch=("${pkgs[@]:i:12}")
        if ( cd "$tmp" || exit 1
             apt_with_timeout 300 "${APT_NET_OPTS[@]}" download "${batch[@]}" </dev/null >>"$LOG_FILE" 2>&1 ); then
            ok_dl=$(( ok_dl + ${#batch[@]} ))
        else
            for ((j = 0; j < ${#batch[@]}; j++)); do
                done_n=$((done_n + 1))
                progress_bar "$done_n" "$total" "Скачивание зависимостей"
                if ( cd "$tmp" || exit 1
                     apt_with_timeout 120 "${APT_NET_OPTS[@]}" download "${batch[$j]}" </dev/null >>"$LOG_FILE" 2>&1 ); then
                    ok_dl=$((ok_dl+1))
                elif apt_with_timeout 300 "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" \
                        install --download-only -y "${batch[$j]}" </dev/null >>"$LOG_FILE" 2>&1; then
                    while IFS= read -r -d '' _dlcached; do
                        safe_copy "$_dlcached" "$tmp" 2>/dev/null || true
                    done < <(find /var/cache/apt/archives -maxdepth 1 \( -name '*.rpm' -o -name '*.deb' \) ! -name 'lock' -print0 2>/dev/null)
                    ok_dl=$((ok_dl+1))
                else
                    fail_dl+=("${batch[$j]}")
                fi
            done
        fi
        done_n=$((done_n + ${#batch[@]})); (( done_n > total )) && done_n=$total
        progress_bar "$done_n" "$total" "Скачивание зависимостей"
    done

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
    if ((${#fail_dl[@]} > 0)); then
        step_warn "Часть пакетов не скачалась: ${fail_dl[*]} (см. техлог)."
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

    # v2.0.7: в режиме «только недостающее» уже установленный RPM той же или
    # более новой версии не переустанавливается (экономия времени).
    if (( OPT_SKIP_INSTALLED == 1 )) && have_cmd rpm; then
        local rn rv rr inst
        IFS='|' read -r rn rv rr < <(
            rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}\n' "$rpm_file" 2>/dev/null
        ) || true
        if [[ -n "$rn" && -n "$rv" ]]; then
            inst="$(rpm -q --qf '%{VERSION}|%{RELEASE}\n' "$rn" 2>/dev/null | head -1)"
            if [[ -n "$inst" ]] && rpm_ver_ge_cached "${inst%|*}-${inst#*|}" "$rv-${rr:-0}"; then
                log "Пропуск уже установленного RPM (версия не ниже): $rpm_file"
                return 0
            fi
        fi
    fi

    log "Установка RPM-файла: $rpm_file"

    if apt_install_pkg "$rpm_file"; then
        return 0
    fi

    if (( OPT_SKIP_INSTALLED == 1 )); then
        # без --replacepkgs: rpm сам пропустит идентичные установленные пакеты
        if rpm -Uvh --oldpackage "$rpm_file" </dev/null >>"$LOG_FILE" 2>&1; then
            return 0
        fi
    elif rpm -Uvh --replacepkgs --oldpackage "$rpm_file" </dev/null >>"$LOG_FILE" 2>&1; then
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

    # v2.0.11: групповой режим ставит ВСЕ переданные RPM за один вызов
    # пакетного менеджера — это критично для КриптоПро: lsb-cprocsp-rdr,
    # kc1, capilite, curl и ca-certs взаимозависимы, поштучная установка
    # (rpm -Uvh по одному файлу) на чистой машине даёт ошибки зависимостей.
    # Флаг-маркер FIRST_ONLY=1: установить только первый RPM из группы
    # (используется для compat-пакета КриптоПро, который должен появиться
    # раньше остальных).
    local FIRST_ONLY=0
    if [[ "${1:-}" == "--first-only" ]]; then
        FIRST_ONLY=1
        shift
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

    if (( FIRST_ONLY == 1 )) && (( ${#rpm_paths[@]} > 1 )); then
        rpm_paths=("${rpm_paths[0]}")
    fi

    log "Групповая установка RPM: ${#files[@]} позиц. (файлов: ${#rpm_paths[@]}, спецификаций: ${#spec_names[@]})"

    # v2.0.7: в режиме «только недостающее» из группы выкидываем RPM, которые
    # уже установлены в версии не ниже — rpm вызывается лишь для того, что
    # реально отсутствует или устарело. Используется один снимок rpm -qa
    # (load_installed_versions_map) вместо rpm -q на каждый файл.
    if (( OPT_SKIP_INSTALLED == 1 )) && (( ${#rpm_paths[@]} > 0 )) && have_cmd rpm; then
        load_installed_versions_map
        local -a todo_paths=()
        local rp rn rv rr inst
        for rp in "${rpm_paths[@]}"; do
            IFS='|' read -r rn rv rr < <(
                rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}\n' "$rp" 2>/dev/null
            ) || true
            if [[ -n "$rn" && -n "$rv" ]] && [[ -n "${INSTALLED_VER_MAP[$rn]:-}" ]]; then
                inst="${INSTALLED_VER_MAP[$rn]}"
                if rpm_ver_ge_cached "${inst%|*}-${inst#*|}" "$rv-${rr:-0}"; then
                    continue
                fi
            fi
            todo_paths+=("$rp")
        done
        if (( ${#todo_paths[@]} < ${#rpm_paths[@]} )); then
            log "Группа RPM: пропущено уже установленных $(( ${#rpm_paths[@]} - ${#todo_paths[@]} )) из ${#rpm_paths[@]}"
        fi
        rpm_paths=("${todo_paths[@]+"${todo_paths[@]}"}")
    fi

    if (( ${#rpm_paths[@]} > 0 )); then
        if apt_install_pkg "${rpm_paths[@]}"; then
            return 0
        fi
        if (( OPT_SKIP_INSTALLED == 1 )); then
            if rpm -Uvh --oldpackage "${rpm_paths[@]}" </dev/null >>"$LOG_FILE" 2>&1; then
                return 0
            fi
        elif rpm -Uvh --replacepkgs --oldpackage "${rpm_paths[@]}" </dev/null >>"$LOG_FILE" 2>&1; then
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

    # v2.0.7: «умный» режим — если стоит та же или более новая ВЕРСИЯ пакета,
    # не переустанавливаем точный NVRA эталона (экономия времени при повторном
    # импорте). При --force-reinstall поведение прежнее: ставим точно эталонную
    # сборку (rpm принимает даунгрейд через --oldpackage).
    if (( OPT_SKIP_INSTALLED == 1 )) && have_cmd rpm; then
        local sname="${nvra%-*}"   # убираем .arch
        sname="${sname%-*}"        # убираем -release → остаётся name-version
        local svrs="${nvra#"$sname"-}"
        local inst
        inst="${INSTALLED_VER_MAP[$sname]:-}"
        if [[ -z "$inst" ]]; then
            load_installed_versions_map
            inst="${INSTALLED_VER_MAP[$sname]:-}"
        fi
        if [[ -n "$inst" ]] && rpm_ver_ge_cached "${inst%|*}-${inst#*|}" "$svrs"; then
            log "Пропуск spec (установлена версия не ниже эталонной): $spec"
            return 0
        fi
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

# ─── Режим «умной» установки (v2.0.7) ─────────────────────────────────────────
# OPT_SKIP_INSTALLED=1 (по умолчанию): перед массовой установкой RPM из
# packages/ уже установленные пакеты (той же или более новой версии)
# отфильтровываются — rpm вызывается только для недостающих. Это главный
# источник экономии времени при повторном импорте (раньше весь набор
# прогонялся через rpm -Uvh --replacepkgs заново).
# Отключается флагом --force-reinstall (или ALT_SYNC_FORCE_REINSTALL=1) —
# тогда поведение прежнее (принудительная переустановка всего).
load_installed_versions_map() {
    INSTALLED_VER_MAP=()
    have_cmd rpm || return 0
    local line name ver rel
    while IFS='|' read -r name ver rel; do
        [[ -z "$name" ]] && continue
        # многостраничные пакеты: оставляем первую запись (стабильно при
        # отсортированном выводе rpm -qa)
        [[ -n "${INSTALLED_VER_MAP[$name]:-}" ]] && continue
        INSTALLED_VER_MAP["$name"]="$ver|$rel"
    done < <(rpm -qa --qf '%{NAME}|%{VERSION}|%{RELEASE}\n' 2>/dev/null | sort -u)
}

# Сравнение версий rpm: возвращает 0, если installed >= wanted.
# При недоступности rpmdev-vercmp используется conservative fallback:
# считаем версии равными только при точном совпадении строк.
rpm_ver_ge() {
    local inst="$1" want="$2" out
    if command -v rpmdev-vercmp >/dev/null 2>&1; then
        out="$(rpmdev-vercmp "$inst" "$want" 2>/dev/null)" || out=""
        case "$out" in
            *" > "*|*" = "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    [[ "$inst" == "$want" ]]
}

filter_rpms_to_install() {
    # stdin: NUL-список путей RPM; stdout: NUL-список тех, что реально нужно ставить
    local f name ver rel inst
    while IFS= read -r -d '' f; do
        IFS='|' read -r name ver rel < <(
            rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}\n' "$f" 2>/dev/null
        ) || true
        if [[ -z "$name" || -z "$ver" ]]; then
            # не удалось прочитать метаданные — ставим на всякий случай
            printf '%s\0' "$f"
            continue
        fi
        inst="${INSTALLED_VER_MAP[$name]:-}"
        if [[ -z "$inst" ]]; then
            printf '%s\0' "$f"   # пакет вообще не установлен
            continue
        fi
        if rpm_ver_ge_cached "${inst%|*}-${inst#*|}" "$ver-$rel"; then
            continue              # стоит та же или более новая версия — пропускаем
        fi
        printf '%s\0' "$f"        # установлена более старая версия — обновляем
    done
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

    local -a rpm_flags=(-Uvh --oldpackage)
    local total_all total_todo
    total_all="$(tr -dc '\0' < "$tmp" | wc -c)"

    if (( OPT_SKIP_INSTALLED == 1 )); then
        load_installed_versions_map
        local filtered
        filtered="$(mktemp "${TMPDIR:-/tmp}/alt-sync-local-rpms-filtered.XXXXXX")" || {
            rm -f "$tmp"; return 0
        }
        filter_rpms_to_install < "$tmp" > "$filtered" 2>>"$LOG_FILE" || true
        # если фильтрация завершилась ошибкой (пусто при непустом входе) —
        # консервативно берём исходный список
        if [[ ! -s "$filtered" && -s "$tmp" && ${#INSTALLED_VER_MAP[@]} -gt 0 ]]; then
            : # пусто legitimately: всё уже установлено — оставляем пустой список
        elif [[ ! -s "$filtered" && -s "$tmp" ]]; then
            cp -- "$tmp" "$filtered" 2>/dev/null || true
        fi
        mv -f -- "$filtered" "$tmp"
        total_todo="$(tr -dc '\0' < "$tmp" | wc -c)"
        info "Недостающих/устаревших RPM из packages/: ${total_todo:-0} из ${total_all:-0} (уже установленные пропущены)."
    else
        rpm_flags+=(--replacepkgs)
        info "Принудительная переустановка всех RPM из packages/ (${total_all:-0}) (--force-reinstall)..."
    fi

    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        step_ok "Все локальные RPM уже установлены — переустановка не требуется"
        return 0
    fi

    xargs -0 -r -n 100 rpm "${rpm_flags[@]}" < "$tmp" </dev/null >>"$LOG_FILE" 2>&1 || true

    if (( OPT_ALLOW_NODEPS == 1 )); then
        info "Повторная установка RPM с --nodeps разрешена меню."
        xargs -0 -r -n 100 rpm -Uvh --nodeps --oldpackage < "$tmp" </dev/null >>"$LOG_FILE" 2>&1 || true
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

    # v2.0.8: если из кэша (/var/cache/apt/archives) скопировано мало RPM —
    # типичная ситуация для ALT, где apt удаляет .rpm после установки, —
    # докачиваем недостающие ВАЖНЫЕ пакеты (список EPSON/PANTUM/CRYPTO и
    # special_packages.txt) напрямую в packages/. Это позволяет развернуть
    # Epson/Pantum на клиенте без интернета. Остальные ~4000 пакетов
    # штатно берутся из репозиториев при импорте.
    local important_file="$LISTS_DIR/special_packages.txt"
    if [[ -d "$PACKAGES_DIR" ]] && have_cmd apt-get &&
       (( OPT_NETWORK_ENABLED == 1 )); then
        local -a imp_pkgs=()
        local ipkg
        while IFS= read -r ipkg; do
            [[ -n "$ipkg" ]] && imp_pkgs+=("$ipkg")
        done < <(
            cat "$important_file" 2>/dev/null || true
            printf '%s\n' "${EPSON_PKGS[@]}" "${PANTUM_PKGS[@]}" "${CRYPTO_PKGS[@]}"
        )

        # дедупликация
        local -A imp_seen=()
        local -a imp_uniq=()
        for ipkg in "${imp_pkgs[@]}"; do
            [[ -n "${imp_seen[$ipkg]:-}" ]] && continue
            imp_seen["$ipkg"]=1
            imp_uniq+=("$ipkg")
        done

        local dl_done=0 dl_fail=0 _apt_ok=0
        # ВАЖНО (v2.0.9): если apt-get download недоступен или ни один пакет не
        # скачался им (например, нет права на запись или особенности apt в p10),
        # включаем резервный канал — apt-get install --download-only с копированием
        # из /var/cache/apt/archives.
        ALT_SYNC_ALLOW_NET=1; export ALT_SYNC_ALLOW_NET
        if (( ${#imp_uniq[@]} > 0 )); then
            if ! have_cmd apt-get; then
                log "INFO: apt-get отсутствует — пропускаю докачку важных RPM."
            else
                for ipkg in "${imp_uniq[@]}"; do
                    # уже есть локально?
                    if find "$PACKAGES_DIR" -maxdepth 1 -type f -iname "${ipkg}-*.rpm" 2>/dev/null | grep -q .; then
                        continue
                    fi
                    if ( cd "$PACKAGES_DIR" && apt_with_timeout 300 "${APT_NET_OPTS[@]}" download "$ipkg" </dev/null >>"$LOG_FILE" 2>&1 ); then
                        dl_done=$((dl_done + 1)); _apt_ok=1
                    else
                        dl_fail=$((dl_fail + 1))
                        log "INFO: важный пакет '$ipkg' недоступен для докачки (не найден в репозиториях)."
                    fi
                done
                # Резервный канал: если apt-get download целиком не сработал (_apt_ok==0)
                # и остались несохранные пакеты — пробуем download-only через кэш apt.
                if (( _apt_ok == 0 && dl_fail > 0 )); then
                    info "apt-get download не сработал — пробую резервный путь: apt-get install --download-only + копирование из /var/cache/apt/archives"
                    local -a still_need=()
                    for ipkg in "${imp_uniq[@]}"; do
                        find "$PACKAGES_DIR" -maxdepth 1 -type f -iname "${ipkg}-*.rpm" 2>/dev/null | grep -q . || still_need+=("$ipkg")
                    done
                    if (( ${#still_need[@]} > 0 )); then
                        local archives_dir="/var/cache/apt/archives"
                        local before_cnt after_cnt copied_fb=0
                        before_cnt=$(find "$archives_dir" -maxdepth 1 -name '*.deb' -o -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l)
                        if env DEBIAN_FRONTEND=noninteractive apt-get "${APT_NET_OPTS[@]}" "${APT_NO_PROMPT_OPTS[@]}" \
                                install --download-only -y "${still_need[@]}" </dev/null >>"$LOG_FILE" 2>&1; then
                            after_cnt=$(find "$archives_dir" -maxdepth 1 \( -name '*.deb' -o -name '*.rpm' \) 2>/dev/null | wc -l)
                            local fb_file
                            while IFS= read -r -d '' fb_file; do
                                safe_copy "$fb_file" "$PACKAGES_DIR" && copied_fb=$((copied_fb + 1))
                            done < <(find "$archives_dir" -maxdepth 1 \( -name '*.deb' -o -name '*.rpm' \) -newermt "-5 minutes" -print0 2>/dev/null)
                            dl_done=$((dl_done + copied_fb)); dl_fail=0
                            log "INFO: резервная докачка: сохранено $copied_fb файлов из $archives_dir (всего стало $after_cnt против $before_cnt)."
                        else
                            warn "Резервная докачка через download-only тоже не удалась (см. техлог)."
                        fi
                    fi
                fi
            fi
        fi

        if (( dl_done > 0 )); then
            log "Докачано важных RPM в локальный репозиторий: $dl_done (ошибок: $dl_fail)"
        elif (( dl_fail > 0 )); then
            info "Важные пакеты не докачаны ($dl_fail) — при импорте будут искаться в сети или через epm play."
        fi
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

# Проверка жёстких пакетных зависимостей (rpm/flock/apt). Вызывается из
# каждого пакетного действия — и из CLI, и из интерактивного меню — чтобы на
# машине без rpm (например, Astra Linux) меню всё равно запускалось, а ясная
# ошибка выдавалась только при реальном выборе экспорт/импорт/CryptoPro.
require_pkg_tools() {
    have_cmd rpm || die "Команда rpm недоступна и не установлена автоматически. Установите пакет rpm вручную."
    have_cmd flock || die "Команда flock недоступна и не установлена автоматически. Установите пакет util-linux вручную."
    if ! have_cmd apt-get && ! have_cmd epm; then
        die "Нет пакетного менеджера (apt-get/epm) — невозможно восстановить слепок. Установите apt или epm."
    fi
}

do_export() {
    require_pkg_tools
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

    # Подготовка инструментов конвертации .deb -> .rpm: драйвер Pantum
    # распространяется как zip с .deb внутри, и eepm распаковывает его 7z,
    # извлекает .deb через dpkg-deb и переупаковывает alien + rpmbuild.
    # Без этих утилит «epm play pantum» падает («dpkg-deb: команда не найдена»)
    # или интерактивно запрашивает их установку, чего в неинтерактивном
    # режиме скрипта быть не должно.
    local conv_tool
    for conv_tool in dpkg alien p7zip unrar cpio rpm-build; do
        if ! rpm -q "$conv_tool" >/dev/null 2>&1; then
            install_package_name "$conv_tool" || true
        fi
    done

    info "Устанавливаю Pantum через epm play pantum..."

    # Эталонная инструкция: «apt-get update && apt-get install epm», затем
    # «epm play pantum» — без флагов --yes/-y (epm play их не поддерживает и
    # считал бы «--yes» именем скрипта). Скрипт play сам скачивает драйверы;
    # запросы подтверждения закрываем пустым вводом.

    # Сначала обновляем системные списки (по инструкции эталона), иначе свежая
    # установка epm может отсутствовать в локальном индексе APT, а повторный
    # вызов update_system_lists_if_needed без флага ничего не делает.
    if (( OPT_NETWORK_ENABLED == 1 )); then
        SYSTEM_LISTS_UPDATED=0
    fi
    update_system_lists_if_needed

    if epm play pantum </dev/null >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    # Повтор с обновлением списков (на случай устаревшего индекса репозитория)
    update_system_lists_if_needed
    if epm play pantum </dev/null >>"$LOG_FILE" 2>&1; then
        return 0
    fi

    step_warn "Не удалось установить Pantum через epm play."

    # Резервный канал: если на эталоне драйвер Pantum был скачан eepm в кэш
    # (/var/cache/epm и т.п.), он попал в vendor-assets.tar и восстановлен на
    # этой машине. Ищем сохранённый .rpm/.deb и ставим напрямую — это позволяет
    # развернуть Pantum даже без доступа к pantum.ru с клиента.
    local pb_dir="$BACKUP_DIR/vendor/restored"
    local cached_rpm=""
    cached_rpm=$(find "$pb_dir" /var/cache/epm /var/tmp -maxdepth 6 \
                     \( -name 'pantum*.rpm' -o -name 'pantum*.deb' \) \
                     -type f 2>/dev/null | sort | tail -n1)
    if [[ -n "$cached_rpm" ]]; then
        info "Найден сохранённый пакет Pantum: $cached_rpm — устанавливаю напрямую..."
        case "$cached_rpm" in
            *.rpm)
                if install_rpm_file "$cached_rpm"; then
                    step_ok "Pantum установлен из сохранённого RPM (резервный канал)."
                    return 0
                fi
                ;;
            *.deb)
                if command -v alien >/dev/null 2>&1 && dpkg-deb -e "$cached_rpm" /tmp 2>/dev/null; then
                    local tmpd
                    tmpd=$(mktemp -d)
                    if ( cd "$tmpd" && alien --to-rpm --scripts "$cached_rpm" ) >>"$LOG_FILE" 2>&1; then
                        local genrpm
                        genrpm=$(find "$tmpd" -maxdepth 1 -name 'pantum*.rpm' | head -n1)
                        if [[ -n "$genrpm" ]] && install_rpm_file "$genrpm"; then
                            step_ok "Pantum установлен из сохранённого DEB (конвертация alien)."
                            rm -rf "$tmpd"
                            return 0
                        fi
                    fi
                    rm -rf "$tmpd"
                fi
                ;;
        esac
        step_warn "Сохранённый пакет Pantum не удалось установить автоматически."
    fi

    step_warn "Выполните вручную от root: apt-get update && apt-get install epm && epm play pantum"
    step_warn "Затем установите принтер через «Параметры печати»."

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

    # v2.0.7: реальный каталог install задаётся в начале файла
    # (INSTALL_DIR="${SCRIPT_DIR}/install"). Раньше здесь был хардкод
    # "$SCRIPT_DIR/install", из-за чего ключ --backup-dir / переменная
    # ALT_SYNC_SCRIPT_DIR не влияли на поиск установщиков КриптоПро.
    add_crypto_search_dir "$INSTALL_DIR"
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

    # v2.0.11: порядок установки как в официальном install.sh КриптоПро:
    #   1) cprocsp-compat-altlinux-* (compat-слой, ставится первым);
    #   2) lsb-cprocsp-base (базовый пакет);
    #   3) остальные — одной группой (rdr/kc1/capilite/curl/ca-certs
    #      взаимозависимы и должны резолвиться вместе).
    local -a ordered=() compat_pkgs=() base_pkgs=() rest_pkgs=()
    local bn
    for f in "${files[@]}"; do
        bn="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        case "$bn" in
            *compat*)              compat_pkgs+=("$f") ;;
            *cprocsp-base*|*lsb-cprocsp-base*) base_pkgs+=("$f") ;;
            *)                     rest_pkgs+=("$f") ;;
        esac
    done
    ordered=(${compat_pkgs[@]+"${compat_pkgs[@]}"})
    ordered+=(${base_pkgs[@]+"${base_pkgs[@]}"})
    ordered+=(${rest_pkgs[@]+"${rest_pkgs[@]}"})
    files=("${ordered[@]}")

    # compat-пакет — отдельно, строго до остальных
    if (( ${#compat_pkgs[@]} > 0 )); then
        install_rpm_files_group --first-only "${compat_pkgs[@]}" || \
            step_warn "CryptoPro compat-пакет не установился (продолжаю с остальными)"
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

# ─── Установка компонентов из папки install/ (v2.0.7) ────────────────────────
# Ожидаемая структура: каждая ПОДПАПКА каталога install/ — это отдельный
# компонент, имя папки = имя компонента (например, «КРИПТО ПРО» с файлами
# установки внутри). Пункт 5 меню выводит checklist со всеми найденными
# компонентами; пользователь отмечает нужные, скрипт ставит только их.
# В каждой выбранной папке последовательно обрабатываются:
#   1) все *.rpm            — через умную групповую установку (пропуск уже
#                             установленных той же/более новой версии);
#   2) установочные скрипты (*.sh, *.run) с известными именами
#      (install_gui.sh, setup.sh, install.sh, run_install.sh и т.п.) —
#     запускаются от root из своего каталога;
#   3) архивы КриптоПро-формата (linux-amd64.tgz/.tar.gz) — распаковываются
#      во временный каталог, там ищется install_gui.sh и RPM.
COMPONENT_ROOTS=()

collect_component_roots() {
    COMPONENT_ROOTS=()

    # приоритет: live-каталог рядом со скриптом, затем копия в бэкапе,
    # затем распакованный assets/install.tar
    add_crypto_search_dir "$INSTALL_DIR"
    add_crypto_search_dir "$BACKUP_DIR/install"

    if [[ -f "$ASSETS_DIR/install.tar" ]]; then
        local tmp
        tmp="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-install-comp.XXXXXX")" || true
        if [[ -n "$tmp" ]]; then
            add_cleanup_tmpdir "$tmp"
            tar_extract_safe "$ASSETS_DIR/install.tar" "$tmp" || true
            add_crypto_search_dir "$tmp/install"
            add_crypto_search_dir "$tmp"
        fi
    fi

    local d sub c exists
    for d in ${CRYPTO_SEARCH_DIRS[@]+"${CRYPTO_SEARCH_DIRS[@]}"}; do
        [[ -d "$d" ]] || continue
        while IFS= read -r -d '' sub; do
            exists=0
            for c in ${COMPONENT_ROOTS[@]+"${COMPONENT_ROOTS[@]}"}; do
                [[ "$c" == "$sub" ]] && { exists=1; break; }
            done
            (( exists )) || COMPONENT_ROOTS+=("$sub")
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done

    (( ${#COMPONENT_ROOTS[@]} > 0 ))
}

# Быстрая проверка: содержит ли папка что-нибудь устанавливаемое?
component_dir_has_payload() {
    local dir="$1"
    find "$dir" -maxdepth 2 \( -type f -iname '*.rpm' \
        -o -type f -name 'install*.sh' -o -type f -name 'setup*.sh' \
        -o -type f -name 'run_install*' -o -type f -iname '*.run' \
        -o -type f -name 'linux-amd64.t*gz' \) -print -quit 2>/dev/null | grep -q .
}

# Автоопределение «установленности» компонента для галки пропуска.
component_already_present() {
    local dir="$1" name="${2:-}"
    local lower_lc="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

    # КриптоПро: если пакеты cprocsp уже стоят — компонент присутствует
    if [[ "$lower_lc" == *"крипто"* || "$lower_lc" == *"crypto"* || "$lower_lc" == *"cprocsp"* ]]; then
        if rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -qiE 'cprocsp|cryptopro'; then
            return 0
        fi
    fi

    # Pantum
    if [[ "$lower_lc" == *pantum* ]]; then
        [[ -d /opt/pantum || -d /usr/lib/pantum || -d /usr/share/pantum ]] && return 0
    fi

    # Epson
    if [[ "$lower_lc" == *epson* ]]; then
        rpm -qa 2>/dev/null | grep -qi 'iscan' && return 0
    fi

    # По всем RPM внутри папки: если каждый уже установлен (не ниже версии) —
    # считаем компонент установленным.
    local any_rpm=0 all_installed=1 rp rn rv rr inst
    while IFS= read -r -d '' rp; do
        any_rpm=1
        IFS='|' read -r rn rv rr < <(
            rpm -qp --qf '%{NAME}|%{VERSION}|%{RELEASE}\n' "$rp" 2>/dev/null
        ) || true
        [[ -z "$rn" || -z "$rv" ]] && { all_installed=0; continue; }
        load_installed_versions_map
        inst="${INSTALLED_VER_MAP[$rn]:-}"
        [[ -z "$inst" ]] && { all_installed=0; continue; }
        rpm_ver_ge_cached "${inst%|*}-${inst#*|}" "$rv-${rr:-0}" || all_installed=0
    done < <(find "$dir" -maxdepth 2 -type f -iname '*.rpm' -print0 2>/dev/null)

    if (( any_rpm == 1 && all_installed == 1 )); then
        return 0
    fi

    return 1
}

# Выбор компонентов: диалог whiptail/dialog --checklist, fallback — нумерованный
# консольный список. Аргументы: имена и пути (массивы COMP_NAMES / COMP_DIRS).
SELECTED_INDICES=()
choose_components_ui() {
    SELECTED_INDICES=()

    local n=${#COMP_NAMES[@]}
    (( n == 0 )) && return 1

    # неинтерактив: ALT_SYNC_COMPONENTS — список имён через запятую; пусто = все
    if [[ "$NONINTERACTIVE" == "1" || "$INTERACTIVE" != "1" ]]; then
        local want="${ALT_SYNC_COMPONENTS:-}"
        if [[ -z "$want" ]]; then
            local i
            for (( i = 0; i < n; i++ )); do SELECTED_INDICES+=("$i"); done
            log "ASK(auto): выбор всех компонентов (${n})"
            return 0
        fi
        local IFS=','
        local w i found
        for w in $want; do
            w="${w//[[:space:]]/}"
            [[ -z "$w" ]] && continue
            found=0
            for (( i = 0; i < n; i++ )); do
                if [[ "${COMP_NAMES[$i]}" == "$w" ]]; then
                    SELECTED_INDICES+=("$i"); found=1; break
                fi
            done
            (( found )) || step_warn "Компонент «$w» не найден в install/"
        done
        log "CLI-выбор компонентов: '${want}' → ${#SELECTED_INDICES[@]} шт."
        (( ${#SELECTED_INDICES[@]} > 0 ))
        return $?
    fi

    if have_cmd whiptail || have_cmd dialog; then
        local prog item
        prog="$(have_cmd whiptail && echo whiptail || echo dialog)"
        local -a args=(--title "Установка из install/ — выберите компоненты" \
                       --checklist "Отметьте компоненты для установки:" 20 70 "$n")
        local i status_tag
        for (( i = 0; i < n; i++ )); do
            if component_already_present "${COMP_DIRS[$i]}" "${COMP_NAMES[$i]}"; then
                status_tag="[уже есть]"
            else
                status_tag="[новый]"
            fi
            args+=("$((i + 1))" "${COMP_NAMES[$i]} ${status_tag}" off)
        done
        local out rc=0
        out="$("$prog" "${args[@]}" 3>&1 1>&2 2>&3)" || rc=$?
        if (( rc != 0 )); then
            log "Выбор компонентов отменён пользователем (rc=$rc)"
            return 1
        fi
        local idx
        for idx in $out; do
            idx="${idx//\"/}"
            [[ "$idx" =~ ^[0-9]+$ ]] && SELECTED_INDICES+=("$((idx - 1))")
        done
        (( ${#SELECTED_INDICES[@]} > 0 ))
        return $?
    fi

    # ── Fallback: текстовое меню (как остальной интерфейс скрипта) ──
    printf '%b\n' "${BOLD}  Компоненты в папке install/:${NC}"
    local i
    for (( i = 0; i < n; i++ )); do
        local tag=""
        if component_already_present "${COMP_DIRS[$i]}" "${COMP_NAMES[$i]}"; then
            tag=" ${YELLOW}[похоже, уже установлен]${NC}"
        fi
        printf '%b\n' "    ${GREEN}$((i + 1)))${NC} ${BOLD}${COMP_NAMES[$i]}${NC}${tag}"
    done
    printf '%b\n' "    ${CYAN}a${NC}) Все компоненты    ${RED}0${NC}) Отмена"
    printf '  Отметьте компоненты через запятую (например: 1,3): '
    if ! read_user_input ""; then
        echo
        return 1
    fi
    local ans="$REPLY_OUT"
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    if [[ -z "$ans" || "$ans" == "0" ]]; then
        return 1
    fi
    if [[ "$ans" == "a" || "$ans" == "ALL" || "$ans" == "все" ]]; then
        for (( i = 0; i < n; i++ )); do SELECTED_INDICES+=("$i"); done
        return 0
    fi
    local tok num
    local IFS=','
    for tok in $ans; do
        num="${tok//[!0-9]/}"
        [[ -z "$num" ]] && continue
        if (( num >= 1 && num <= n )); then
            SELECTED_INDICES+=("$((num - 1))")
        else
            step_warn "Неверный номер компонента: $tok"
        fi
    done
    unset IFS
    (( ${#SELECTED_INDICES[@]} > 0 ))
}

# Установка одного компонента из корня его папки. Возвращает 0, если было
# установлено что-либо (или компонент уже присутствовал), 1 — если ничего
# найти не удалось.
install_component_from_dir() {
    local root="$1" name="$2"
    local did_something=0

    info "Компонент «$name»: сканирую $root"

    local lower_lc_name
    lower_lc_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    local is_cryptopro_comp=0
    if [[ "$lower_lc_name" == *"крипто"* || "$lower_lc_name" == *"crypto"* || "$lower_lc_name" == *cprocsp* ]]; then
        is_cryptopro_comp=1
    fi

    # 1) RPM компонента — группой (умный режим сам отфильтрует установленное).
    #    Для КриптоПро: сначала compat-пакет, затем base, затем остальные
    #    одной группой — как в официальном install.sh вендора.
    local -a comp_rpms=()
    local rf
    while IFS= read -r -d '' rf; do
        comp_rpms+=("$rf")
    done < <(find "$root" -maxdepth 3 -type f -iname '*.rpm' -print0 2>/dev/null | sort -z)

    if (( ${#comp_rpms[@]} > 0 )); then
        if (( is_cryptopro_comp == 1 )); then
            local -a cp_compat=() cp_base=() cp_rest=()
            local cbn
            for rf in "${comp_rpms[@]}"; do
                cbn="$(basename "$rf" | tr '[:upper:]' '[:lower:]')"
                case "$cbn" in
                    *compat*)                      cp_compat+=("$rf") ;;
                    *cprocsp-base*|*lsb-cprocsp-base*) cp_base+=("$rf") ;;
                    *)                             cp_rest+=("$rf") ;;
                esac
            done
            if (( ${#cp_compat[@]} > 0 )); then
                install_rpm_files_group --first-only "${cp_compat[@]}" || \
                    step_warn "Компонент «$name»: compat-пакет не установился (продолжаю)"
            fi
            if (( ${#cp_base[@]} > 0 )); then
                install_rpm_files_group "${cp_base[@]}" || \
                    step_warn "Компонент «$name»: base-пакет не установился (продолжаю)"
            fi
            if (( ${#cp_rest[@]} > 0 )); then
                install_rpm_files_group "${cp_rest[@]}" || \
                    step_warn "Компонент «$name»: часть RPM не установилась"
            fi
            did_something=1
        elif install_rpm_files_group "${comp_rpms[@]}"; then
            info "Компонент «$name»: RPM обработаны (${#comp_rpms[@]} шт.)"
            did_something=1
        else
            step_warn "Компонент «$name»: часть RPM не установилась"
            did_something=1
        fi
    fi

    # 2) Архивы формата CryptoPro (linux-amd64.tgz/.tar.gz) → install_gui.sh/RPM
    local archive extract_dir gf
    while IFS= read -r -d '' archive; do
        extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/alt-sync-comp-extract.XXXXXX")" || continue
        add_cleanup_tmpdir "$extract_dir"
        if extract_archive_to_dir "$archive" "$extract_dir"; then
            local -a extra_rpms=()
            while IFS= read -r -d '' gf; do
                extra_rpms+=("$gf")
            done < <(find "$extract_dir" -type f -iname '*.rpm' -print0 2>/dev/null | sort -z)
            if (( ${#extra_rpms[@]} > 0 )); then
                install_rpm_files_group "${extra_rpms[@]}" && did_something=1
            fi
            local gui
            gui="$(find "$extract_dir" -maxdepth 4 -type f -name install_gui.sh -print -quit 2>/dev/null || true)"
            if [[ -n "$gui" ]]; then
                if run_component_script "$(dirname "$gui")" "install_gui.sh" "$name"; then
                    did_something=1
                fi
            fi
        fi
    done < <(find "$root" -maxdepth 3 -type f \( -name 'linux-amd64.tgz' -o -name 'linux-amd64.tar.gz' \) -print0 2>/dev/null)

    # 3) Установочные скрипты в самой папке компонента
    local sf sf_base
    while IFS= read -r -d '' sf; do
        sf_base="$(basename "$sf")"
        case "$sf_base" in
            uninstall*|*remove*)
                continue ;;
        esac
        if run_component_script "$(dirname "$sf")" "$sf_base" "$name"; then
            did_something=1
        fi
    done < <(
        find "$root" -maxdepth 2 -type f \
            \( -name 'install*.sh' -o -name 'setup*.sh' -o -name 'run_install*' -o -iname '*.run' \) \
            -print0 2>/dev/null | sort -z
    )

    if (( did_something == 0 )); then
        step_warn "Компонент «$name»: в папке не найдено ни RPM, ни установочных скриптов — пропущен."
        return 1
    fi

    return 0
}

run_component_script() {
    local dir="$1" script_name="$2" comp="$3"
    local spath="$dir/$script_name"

    [[ -f "$spath" ]] || return 1

    # повторный запуск того же скрипта в рамках одной сессии не нужен
    [[ -n "${RUN_COMPONENT_SCRIPTS_DONE[$spath]+x}" ]] && return 0

    if [[ ! -t 0 || ! -t 1 ]]; then
        info "Нет TTY — интерактивный установщик «$script_name» ($comp) не запускаю. Вручную: cd $(printf '%q' "$dir") && bash ./$(printf '%q' "$script_name")"
        RUN_COMPONENT_SCRIPTS_DONE["$spath"]=1
        return 0
    fi

    info "Запускаю установщик компонента «$comp»: $spath"
    log "RUN component installer: $spath (cwd=$dir)"
    RUN_COMPONENT_SCRIPTS_DONE["$spath"]=1

    if (
        cd "$dir" || exit 1
        if [[ -x "$spath" ]]; then
            "$spath"
        else
            bash "$spath"
        fi
    ); then
        return 0
    fi

    step_warn "Установщик $script_name ($comp) завершился с ошибкой или прерван."
    return 1
}

declare -A RUN_COMPONENT_SCRIPTS_DONE=()

# Есть ли в install/ подпапки-компоненты с устанавливаемым содержимым?
# Используется пунктом 5 меню для выбора между checklist-режимом и прежней
# узкой логикой CryptoPro.
components_available() {
    prepare_crypto_search_dirs
    collect_component_roots || return 1

    local r
    for r in "${COMPONENT_ROOTS[@]}"; do
        if component_dir_has_payload "$r"; then
            return 0
        fi
    done
    return 1
}

do_install_from_folder() {
    require_pkg_tools
    ensure_rpm_index

    prepare_crypto_search_dirs

    if ! collect_component_roots; then
        step_warn "В папке install/ нет подпапок-компонентов."
        printf '%b\n' "${CYAN}  ℹ️  Ожидается структура: install/<Имя компонента>/файлы установки (например, install/КРИПТО ПРО/...)${NC}"
        write_summary_report "Установка из install/ (компоненты не найдены)"
        return 1
    fi

    # Собираем уникальные имена компонентов (одинаковые имена из разных roots
    # сливаются — приоритет у первого добавленного root)
    COMP_NAMES=()
    COMP_DIRS=()
    declare -A seen_names=()
    local r base
    for r in "${COMPONENT_ROOTS[@]}"; do
        base="$(basename "$r")"
        [[ -z "${seen_names[$base]:-}" ]] || continue
        if ! component_dir_has_payload "$r"; then
            continue
        fi
        seen_names["$base"]=1
        COMP_NAMES+=("$base")
        COMP_DIRS+=("$r")
    done

    if (( ${#COMP_NAMES[@]} == 0 )); then
        step_warn "Ни одна подпапка install/ не содержит устанавливаемых файлов (*.rpm / install*.sh / *.run / linux-amd64.tgz)."
        write_summary_report "Установка из install/ (пустые компоненты)"
        return 1
    fi

    if ! choose_components_ui; then
        info "Установка из install/ отменена."
        return 1
    fi

    init_steps "$(( ${#SELECTED_INDICES[@]} + 1 ))"
    step_start "Подготовка локального репозитория"
    if [[ -d "$PACKAGES_DIR" ]]; then
        prepare_local_apt
        apt_update_local || true
    fi
    step_ok "Локальный репозиторий готов"

    local idx ok=0 fail=0
    for idx in "${SELECTED_INDICES[@]}"; do
        step_start "Компонент: ${COMP_NAMES[$idx]}"
        if install_component_from_dir "${COMP_DIRS[$idx]}" "${COMP_NAMES[$idx]}"; then
            step_ok "Компонент «${COMP_NAMES[$idx]}» обработан"
            ok=$((ok + 1))
        else
            step_warn "Компонент «${COMP_NAMES[$idx]}» не установлен"
            fail=$((fail + 1))
        fi
    done

    info "Итог: успешно $ok, с предупреждениями/ошибками $fail."
    write_summary_report "Установка из install/: выбрано ${#SELECTED_INDICES[@]}, готово $ok, проблем $fail"
    (( fail == 0 ))
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
    require_pkg_tools
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
    require_pkg_tools
    init_steps 3

    step_start "Восстановление install-ассетов"
    restore_assets
    step_ok "Ассеты обработаны"

    # v2.0.7: если в install/ есть подпапки-компоненты (имя папки = имя
    # компонента, например «КРИПТО ПРО»), показываем checklist и ставим
    # только выбранное. Если компонентов нет — прежняя логика CryptoPro.
    if components_available; then
        do_install_from_folder
        return $?
    fi

    info "Подпапок-компонентов в install/ не найдено — работаю по прежней схеме (только CryptoPro)."

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

    HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
    if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
        step_warn "Домашний каталог не найден для пользователя: $TARGET_USER"
        return 1
    fi

    TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
    return 0
}

choose_target_user() {
    local default_user
    default_user="$(detect_default_user || true)"

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
            if ! read_user_input ""; then
                return 1
            fi
            TARGET_USER="$REPLY_OUT"
        fi
    else
        printf 'Введите имя пользователя для профиля: '
        if ! read_user_input ""; then
            return 1
        fi
        TARGET_USER="$REPLY_OUT"
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
    if [[ "$NONINTERACTIVE" == "1" ]]; then
        full_auto=1
    fi

    if (( full_auto )); then
        OPT_SKIP_VENDOR_ASSETS=0
        OPT_BACKUP_USER=1
        if [[ -n "${ALT_SYNC_TARGET_USER:-}" ]]; then
            TARGET_USER="$ALT_SYNC_TARGET_USER"
        else
            TARGET_USER="$(detect_default_user || true)"
        fi
        if [[ -z "$TARGET_USER" ]] || ! validate_user; then
            step_warn "Не задан/недействителен пользователь профиля (ALT_SYNC_TARGET_USER) — профиль пропущен."
            TARGET_USER=""; HOME_DIR=""; TARGET_GROUP=""
            OPT_BACKUP_USER=0
            OPT_SKIP_MOZILLA=1
        else
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
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
    if [[ "$NONINTERACTIVE" == "1" ]]; then
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
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
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

    # v2.0.7: режим «умной» установки по умолчанию включён; предлагаем
    # принудительную переустановку всего набора (прежнее поведение).
    if ask_yes_no "Принудительно переустанавливать ВСЕ пакеты эталона (медленнее)? Пустая строка = только недостающие/обновляемые" n; then
        OPT_SKIP_INSTALLED=0
    else
        OPT_SKIP_INSTALLED=1
    fi
    VER_GE_CACHE=()

    return 0
}

prepare_import_offline() {
    OPT_VERIFY_BACKUP=1
    OPT_SNAPSHOT=1

    if [[ "$NONINTERACTIVE" == "1" ]]; then
        OPT_SKIP_VENDOR_RESTORE=0
        OPT_USE_NETWORK_IMPORT=0
        OPT_NETWORK_ENABLED=0
        SYSTEM_LISTS_UPDATED=0
        OPT_FORCE_EPM_PLAY=0
        OPT_FORCE_CRYPTO_INSTALLER=0
        OPT_ALLOW_NODEPS=0
        if [[ -n "${ALT_SYNC_TARGET_USER:-}" ]] && validate_user; then
            TARGET_USER="$ALT_SYNC_TARGET_USER"
            HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"; HOME_DIR="${HOME_DIR:-/home/$TARGET_USER}"
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
    if [[ "$NONINTERACTIVE" == "1" ]]; then
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
    clear 2>/dev/null || printf '\n\n'
    printf '%b\n' "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    printf '%b\n' "${BOLD}${CYAN}║   ALT LINUX UNIVERSAL SYNC v$SCRIPT_VERSION (консоль)        ║${NC}"
    printf '%b\n' "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}1${NC}) Экспорт эталона: с докачкой недостающих RPM            ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}2${NC}) Экспорт эталона: только локальные RPM                  ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${YELLOW}3${NC}) Импорт на копию железа: интерактивный                  ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${YELLOW}4${NC}) Импорт на копию железа: полностью офлайн               ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${BLUE}5${NC}) Установка из install/ (выбор компонентов; CryptoPro)   ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${CYAN}6${NC}) Проверить бэкап (целостность)                          ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${GREEN}7${NC}) Скачать компоненты в офлайн-кэш (нужен интернет)       ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${MAGENTA}8${NC}) Сводка системы и текущих настроек                      ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${BLUE}9${NC}) Создать ярлык в меню приложений + на рабочий стол       ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}║${NC}  ${RED}0${NC}) Выход                                                  ${BOLD}${CYAN}║${NC}"
    printf '%b\n' "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

    printf '%b\n' "  ${BOLD}Скрипт:${NC}   $SELF"
    printf '%b\n' "  ${BOLD}Бэкап:${NC}    $BACKUP_DIR"
    printf '%b\n' "  ${BOLD}Лог:${NC}      $LOG_FILE"
    if [[ $EUID -eq 0 ]]; then
        printf '%b\n' "  ${BOLD}Права:${NC}    ${GREEN}root ✓${NC}"
    else
        printf '%b\n' "  ${BOLD}Права:${NC}    ${RED}нет root ✗${NC}"
    fi
    # Индикатор вычисляется один раз перед циклом меню (см. main). Если он пуст
    # (например, show_menu вызвана вне основного цикла) — показываем нейтрально.
    if [[ -n "${PKG_TOOLS_STATUS:-}" ]]; then
        printf '%b\n' "  ${BOLD}Пакетные инструменты:${NC} $PKG_TOOLS_STATUS"
    fi

    if deps_cache_available; then
        local nrpm
        nrpm="$(find "$DEPS_CACHE_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l || true)"
        printf '%b\n' "  ${BOLD}Офлайн-кэш зависимостей:${NC} ${GREEN}${nrpm} RPM${NC} ($DEPS_CACHE_DIR)"
    else
        printf '%b\n' "  ${BOLD}Офлайн-кэш зависимостей:${NC} ${YELLOW}отсутствует${NC} (на эталоне выполните п.7 или: sudo bash $SELF fetch-deps)"
    fi

    if [[ -d "$PACKAGES_DIR" ]]; then
        local npkg nfree
        npkg="$(find "$PACKAGES_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l || true)"
        nfree="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
        printf '%b\n' "  ${BOLD}Пакеты в бэкапе:${NC} ${npkg:-0} RPM ${CYAN}(свободно на диске: ${nfree:-?} МБ)${NC}"
    else
        printf '%b\n' "  ${BOLD}Пакеты в бэкапе:${NC} ещё не созданы (выполните экспорт — п.1 или п.2)"
    fi

    if [[ -r "$MACHINE_ID_FILE" ]]; then
        local cur stor
        cur="$(generate_machine_id || true)"
        stor="$(tr -d '\r\n ' < "$MACHINE_ID_FILE" 2>/dev/null || true)"
        if [[ "$cur" == "$stor" ]]; then
            printf '%b\n' "  🔒 Статус: ${GREEN}Эталон совпадает с этим железом${NC}"
        else
            printf '%b\n' "  🔒 Статус: ${RED}Чужая машина (маркер эталона не совпадает)${NC}"
        fi
    elif [[ -f "$MACHINE_ID_FILE" ]]; then
        printf '%b\n' "  🔒 Статус: ${YELLOW}Маркер существует, но не читается${NC}"
    else
        printf '%b\n' "  🔒 Статус: ${YELLOW}Маркер эталона ещё не создан${NC}"
    fi

    echo
}

pause_console() {
    # v2.0.5: через read_user_input — работает и при stdin=TTY (случай
    # «su -c» из konsole, где /dev/tty перекрыт su и даёт EIO), и при
    # доступном только /dev/tty. Без паузы результат действия мгновенно
    # прокручивался и меню перерисовывалась в цикле — окно выглядело «зависшим».
    [[ "$INTERACTIVE" == "1" && "$NONINTERACTIVE" != "1" ]] || return 0
    printf '\n%s' "  Нажмите ENTER для возврата в меню…"
    read_user_input "" || true
}

# ─── Ярлык в графической оболочке (пункт меню 9) ──────────────────────────────
# Позволяет запускать скрипт из файлового менеджера / меню приложений:
# двойной клик по .desktop открывает терминал, в котором запускается alt_sync.sh
# (при необходимости — с запросом пароля через sudo/pkexec в этом же терминале).
create_desktop_shortcut() {
    # Определяем «настоящего» пользователя оболочки (если запущены от root через sudo)
    local target_uid="${SUDO_UID:-}" target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" ]]; then
        # из окружения вызывающего процесса /proc/1 не берём; пробуем loginctl
        target_user="$(loginctl list-users --no-legend 2>/dev/null | awk 'NR==1{print $NF}')" || true
    fi
    if [[ $EUID -eq 0 && -z "$target_user" ]]; then
        step_warn "Не удалось определить пользователя graphical-сессии (запустите пункт 9 из-под обычного пользователя или задайте SUDO_USER)."
        return 1
    fi
    if [[ $EUID -ne 0 ]]; then
        target_uid="$(id -u || true)"
        target_user="$(id -un || true)"
    fi
    # fallback: если uid не определён (например, запуск через su без SUDO_UID),
    # берём uid найденного пользователя
    if [[ -z "$target_uid" && -n "$target_user" ]]; then
        target_uid="$(id -u "$target_user" 2>/dev/null)" || target_uid=""
    fi
    if ! ask_yes_no "Создать ярлык «ALT Linux Universal Sync» в меню приложений и на рабочем столе?" y; then
        printf '  Создание ярлыка отменено.\n'
        return 0
    fi
    local home_dir
    if [[ -n "$target_user" ]]; then
        home_dir="$(getent passwd "$target_user" | cut -d: -f6 || true)"
    else
        home_dir="$HOME"
    fi
    if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
        step_warn "Домашний каталог пользователя не найден ($home_dir)."
        return 1
    fi

    local term_exec=""
    local t
    for t in gnome-terminal konsole xfce4-terminal mate-terminal lxterminal qterminal yterm st alacritty kitty xterm; do
        if command -v "$t" >/dev/null 2>&1; then term_exec="$t"; break; fi
    done
    # x-terminal-emulator — только если он реально существует в системе
    if [[ -z "$term_exec" ]] && command -v x-terminal-emulator >/dev/null 2>&1; then
        term_exec="x-terminal-emulator"
    fi
    if [[ -z "$term_exec" ]]; then
        step_warn "Терминал не найден (gnome-terminal/konsole/xfce4-terminal/xterm...)."
        step_warn "Ярлык создаётся с x-terminal-emulator: без терминала запуск по двойному клику не откроет окно."
        term_exec="x-terminal-emulator"
    fi

    # Команда внутри терминала: повышение прав выполняет сам скрипт
    # (sudo -> su -> pkexec с учётом sudoers), поэтому здесь просто bash.
    # Путь экранирован через printf %q — корректно работает даже если он
    # содержит пробелы или спецсимволы. Флаг NO_AUTOINSTALL НЕ подставляется:
    # при отсутствии зависимостей скрипт сам спросит, установить ли их.
    local run_cmd="bash ${SELF_NO_ESCAPE}"

    local launch_line
    case "$term_exec" in
        gnome-terminal|x-terminal-emulator|mate-terminal)
            launch_line="$term_exec -- bash -lc \"$run_cmd\"" ;;
        yterm)
            launch_line="$term_exec bash -lc \"$run_cmd\"" ;;
        konsole|xfce4-terminal|qterminal|lxterminal|st|alacritty|kitty|xterm)
            launch_line="$term_exec -e bash -lc \"$run_cmd\"" ;;
        *)
            launch_line="$term_exec -e bash -lc \"$run_cmd\"" ;;
    esac

    local desktop_name="ALT Linux Universal Sync"
    local fname="alt-sync.desktop"

    local desktop_content
    desktop_content=$(cat <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$desktop_name
Name[ru_RU]=$desktop_name
Comment=Синхронизация эталона ALT Linux (консольная утилита)
Comment[ru_RU]=Синхронизация эталона ALT Linux (консольная утилита)
Exec=$launch_line
Icon=utilities-system-monitor
Terminal=false
Categories=System;FileTools;Utility;
StartupNotify=true
Keywords=alt;linux;sync;backup;ethalon;
EOF
)

    local apps_dir="$home_dir/.local/share/applications"
    mkdir -p "$apps_dir"
    printf '%s\n' "$desktop_content" > "$apps_dir/$fname"
    chmod 644 "$apps_dir/$fname"
    chown "$target_uid:$target_user" "$apps_dir/$fname" 2>/dev/null || true

    local ok_count=1
    step_ok "Ярлык создан в меню приложений: $apps_dir/$fname"

    # Рабочий стол
    local desk_dir=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        desk_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi
    [[ -z "$desk_dir" || ! -d "$desk_dir" ]] && desk_dir="$home_dir/Desktop"
    if [[ -d "$home_dir/Рабочий стол" ]]; then desk_dir="$home_dir/Рабочий стол"; fi
    if [[ -d "$desk_dir" ]]; then
        cp -f "$apps_dir/$fname" "$desk_dir/$fname"
        chmod +x "$desk_dir/$fname"
        chown "$target_uid:$target_user" "$desk_dir/$fname" 2>/dev/null || true
        # Для Nautilus/Mate/Cinnamon: явно разрешаем исполнение
        gio set "$desk_dir/$fname" metadata::trusted true 2>/dev/null || true
        ok_count=$((ok_count+1))
        step_ok "Ярлык скопирован на рабочий стол: $desk_dir/$fname"
    else
        step_warn "Каталог рабочего стола не найден — пропущено."
    fi

    # Автозапуск (опционально — не включаем без спроса)
    printf '\n  %bТерминал для запуска:%b %s\n' "$BOLD" "$NC" "$term_exec"
    printf '  %bЧтобы запустить:%b откройте меню приложений → «%s»,\n' "$BOLD" "$NC" "$desktop_name"
    printf '  или дважды щёлкните по ярлыку на рабочем столе.\n'
    printf '  Откроется окно терминала со старым интерактивным меню.\n'
    return 0
}

system_summary() {
    printf '\n%b\n' "${BOLD}${CYAN}━━━ Сводка системы ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf '  Хост:              %s\n' "$(hostname 2>/dev/null || echo '?')"
    local osname
    osname="$(grep -m1 PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || true)"
    printf '  ОС:                %s\n' "${osname:-?}"
    printf '  Ядро:              %s\n' "$(uname -r 2>/dev/null || echo '?')"
    printf '  Пользователь:      %s (uid=%s)\n' "$(id -un)" "$(id -u)"
    if [[ $EUID -eq 0 ]]; then
        printf '  Root-права:        да\n'
    else
        printf '  Root-права:        НЕТ — часть операций будет недоступна\n'
    fi
    printf '  Каталог скрипта:   %s\n' "$SCRIPT_DIR"
    printf '  Каталог бэкапа:    %s\n' "$BACKUP_DIR"
    printf '  Текущий лог:       %s\n' "$LOG_FILE"
    printf '  Последний лог:     %s\n' "$LOG_DIR/alt_sync_latest.log"
    local ncpu ram diskfree
    ncpu="$(nproc 2>/dev/null || echo '?')"
    ram="$(free -h 2>/dev/null | awk '/^Mem:/{print $2"/"$7}' || true)"
    # «|| true» обязательны: под set -e непустой вывод awk НЕ гарантирует rc=0,
    # а пустая команда (df/free отсутствуют) с rc=1 убивала весь скрипт прямо
    # здесь — окно закрывалось сразу после «Сводки системы».
    diskfree="$(df -Ph "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"
    printf '  CPU: %s ядер | RAM всего/свободно: %s | свободно на диске бэкапа: %s\n' \
        "$ncpu" "${ram:-?}" "${diskfree:-?}"
    if command -v nmcli >/dev/null 2>&1; then
        local nst
        nst="$(nmcli -t -f STATE networking status 2>/dev/null | head -1 || true)"
        printf '  Сеть (NetworkManager): %s\n' "${nst:-неизвестно}"
    fi
    if [[ -d "$PACKAGES_DIR" ]]; then
        local npkg nbak
        npkg="$(find "$PACKAGES_DIR" -maxdepth 1 -name '*.rpm' 2>/dev/null | wc -l || true)"
        nbak="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || true)"
        printf '  Бэкап:             %s RPM, общий размер ~%s\n' "$npkg" "${nbak:-?}"
    fi
    if deps_cache_available; then
        local ndep
        ndep="$(find "$DEPS_CACHE_DIR" -maxdepth 1 \( -name '*.rpm' -o -name '*.deb' \) 2>/dev/null | wc -l || true)"
        printf '  Офлайн-кэш:        %s пакетов (%s)\n' "$ndep" "$DEPS_CACHE_DIR"
    fi
    if [[ -r "$MACHINE_ID_FILE" ]]; then
        printf '  Маркер эталона:    %s\n' "$(head -c 64 "$MACHINE_ID_FILE" 2>/dev/null || true)"
    fi
    printf '  Версия скрипта:    %s\n' "$SCRIPT_VERSION"
    printf '%b\n' "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    pause_console
}

usage() {
    cat <<EOF
ALT Linux Universal Sync v$SCRIPT_VERSION — консольная версия (GUI-оболочка удалена)

Интерактивный запуск (меню в терминале):
  sudo bash $0

CLI-режим (для автоматизации; без аргументов — интерактивное меню):
  sudo bash $0 <действие> [флаги]

Действия:
  export            Экспорт эталона (аналог меню 1, с докачкой RPM из сети)
  export-offline    Экспорт эталона только из локальных RPM (аналог меню 2)
  import            Интерактивный импорт на копию железа (аналог меню 3)
  import-offline    Полностью офлайн-импорт (аналог меню 4)
  cryptopro         Только CryptoPro + доп. RPM (аналог меню 5; если в
                    install/ есть подпапки-компоненты — покажет их выбор)
  install-components Выбор компонентов из подпапок install/ (checklist):
                    имя папки = имя компонента (например, «КРИПТО ПРО»);
                    устанавливаются RPM/install*.sh/*.run только из
                    ОТМЕЧЕННЫХ папок; уже установленное пропускается.
  verify            Проверка бэкапа (аналог меню 6)
  fetch-deps        [ЭТАЛОН, нужен интернет] Скачать все зависимости скрипта
                    в офлайн-кэш deps-rpm/ рядом со скриптом — для установки
                    на компьютерах БЕЗ интернета
  desktop-shortcut  Создать ярлык .desktop в меню приложений и на рабочем столе:
                    двойной клик открывает терминал с интерактивным меню этого
                    скрипта (аналог пункта 9 меню; удобно запускать из оболочки)

Флаги:
  -y, --yes         Неинтерактивный режим: на все вопросы отвечать «да»
      --defaults    Неинтерактивный режим: значения по умолчанию каждого вопроса
      --with-network-keys    Включить в экспорт Wi-Fi пароли NetworkManager (секреты!)
      --without-network-keys Не включать Wi-Fi пароли (по умолчанию)
      --with-mozilla         Включить в экспорт ~/.mozilla — профили браузера (секреты!)
      --without-mozilla      Не включать ~/.mozilla (по умолчанию)
      --user NAME            Пользователь, чей профиль бэкапится/восстанавливается
      --backup-dir DIR       Каталог бэкапа (по умолчанию рядом со скриптом)
      --force-reinstall      Принудительно переустанавливать ВСЕ пакеты
                             (прежнее поведение; по умолчанию скрипт ставит
                             только недостающие/обновляемые — быстрее)
      --skip-installed       Явно включить режим «только недостающее»
                             (по умолчанию включён)
      --no-color             Отключить цветной вывод
  -h, --help        Эта справка
  -V, --version     Версия

Переменные окружения:
  ALT_SYNC_NONINTERACTIVE=1       То же, что --yes/--defaults
  ALT_SYNC_TARGET_USER=name       Целевой пользователь профиля
  ALT_SYNC_BACKUP_DIR=DIR         Каталог бэкапа (то же, что --backup-dir)
  ALT_SYNC_BACKUP_NETWORK_KEYS=1  То же, что --with-network-keys
  ALT_SYNC_BACKUP_MOZILLA=1       То же, что --with-mozilla
  ALT_SYNC_ALLOW_ROOT_RESTART=0   Запретить автоперезапуск через sudo/pkexec/su
  ALT_SYNC_NO_ESCALATE=1          Работать без повышения прав (предупреждение)
  ALT_SYNC_NO_AUTOINSTALL=1       Отключить автоустановку зависимостей
  ALT_SYNC_DEPS_CACHE_DIR=DIR     Каталог офлайн-кэша зависимостей
  ALT_SYNC_APT_INTERACTIVE=1      Разрешить диалоги apt (по умолчанию неинтерактивно)
  ALT_SYNC_FORCE_REINSTALL=1      То же, что --force-reinstall
  ALT_SYNC_COMPONENTS="a,b"       Неинтерактивный выбор компонентов install/
                                  через запятую (пусто = все)
  NO_COLOR=1                      Отключить цветной вывод

Прогресс и отмена (консольный аналог окна прогресса прежней GUI-версии):
  • каждый шаг печатается с нумерацией «Шаг N/M», временем и процентом прогресса;
  • весь вывод дублируется в техлог (путь виден в меню и в начале работы);
  • отмена — Ctrl+C: скрипт корректно останавливается на ближайшей контрольной
    точке и пишет «CANCEL» в лог;
  • итоговый отчёт OK/WARN/FAIL выводится в конце каждой задачи.

Логирование:
  Логи пишутся РЯДОМ СО СКРИПТОМ в каталоге logs/ (при недоступности — /tmp):
  techлог alt_sync_<дата>_<время>_<pid>.log, ссылка на последний — alt_sync_latest.log,
  итоговые отчёты alt_sync_report_*.txt, hardware_diff.txt и т.д.

Примеры:
  sudo bash $0                                # интерактивное меню
  sudo bash $0 export --yes                   # полностью автоматический экспорт
  sudo bash $0 export --with-network-keys --with-mozilla --user ivan
  sudo bash $0 import-offline --defaults --user ivan
  sudo bash $0 verify
  sudo bash $0 fetch-deps                     # эталон: скачать кэш зависимостей
EOF
}

main() {
    local action=""

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
            --no-color)
                NO_COLOR=1; export NO_COLOR
                RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; NC=''
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
            --force-reinstall)
                OPT_SKIP_INSTALLED=0
                VER_GE_CACHE=()
                ;;
            --skip-installed)
                OPT_SKIP_INSTALLED=1
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
            export|export-offline|import|import-offline|cryptopro|install-components|verify|fetch-deps|desktop-shortcut)
                if [[ -n "$action" && "$action" != "$1" ]]; then
                    die "Нельзя указать два действия одновременно: '$action' и '$1'"
                fi
                action="$1"
                if [[ "${ALT_SYNC_ELEVATED:-0}" == "1" ]]; then
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

    # ── Приветствие показываем СРАЗУ, до любых проверок зависимостей, чтобы
    # пользователь сразу видел меню/информацию в терминале (раньше при
    # ALT_SYNC_NO_AUTOINSTALL=1 вывод уходил только в лог, и окно казалось
    # «зависшим»).
    printf 'alt_sync v%s | SELF=%s | BACKUP_DIR=%s | ТЕРМИНАЛ ВВОДА=%s\n' \
        "$SCRIPT_VERSION" "$SELF" "$BACKUP_DIR" "$( [[ "$INTERACTIVE" == "1" ]] && { [[ -n "$INPUT_TTY" ]] && echo "/dev/tty" || echo "stdin(tty)"; } || echo "<нет>" )"

    if ((${#MISSING_BOOTSTRAP[@]} > 0)) || ((${#MISSING_OPTIONAL_COMMANDS[@]} > 0)); then
        local net_allowed=0
        if [[ "${ALT_SYNC_NO_AUTOINSTALL:-0}" == "1" ]]; then
            log "INFO: ALT_SYNC_NO_AUTOINSTALL=1 — автоустановка зависимостей отключена; использую доступные механизмы."
        elif [[ "${ALT_SYNC_ALLOW_NET:-0}" == "1" ]]; then
            net_allowed=1
        elif [[ "$NONINTERACTIVE" != "1" && "$INTERACTIVE" == "1" ]]; then
            if ask_yes_no "Не хватает зависимостей (${MISSING_BOOTSTRAP[*]:-} ${MISSING_OPTIONAL_COMMANDS[*]:-}). Установить их из репозитория? (нужен интернет)" y; then
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
        # Раньше здесь был безусловный die() при отсутствии rpm/flock/apt —
        # на машине без /bin/rpm (Astra Linux) окно закрывалось сразу после
        # баннера, так и не показав меню. Теперь жёсткие проверки перенесены
        # в require_pkg_tools(), который вызывается из каждого пакетного
        # действия (do_export/do_import/do_cryptopro_only) — и из CLI, и из
        # интерактивного меню. Меню и пункты «Сводка», «Проверка бэкапа»,
        # «Ярлык» работают и без rpm.
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
            install-components)
                prepare_crypto_interactive || rc=$?
                (( rc == 0 )) && { do_install_from_folder || rc=$?; }
                ;;
            verify)
                do_verify || rc=$?
                ;;
            fetch-deps)
                fetch_deps_cache || rc=$?
                ;;
            desktop-shortcut)
                create_desktop_shortcut || rc=$?
                ;;
        esac
        if (( rc == 0 )); then
            log "CLI action '$action' finished successfully"
        else
            step_warn "Действие '$action' завершилось с кодом $rc."
        fi
        return "$rc"
    fi

    # Защита от «невидимого» интерактивного меню: если stdin не терминал и
    # /dev/tty недоступен (например, /dev/null из GUI-обёртки), read мгновенно
    # завершится ошибкой и скрипт бесконечно перерисует меню. В таком
    # окружении показывать TUI бессмысленно — выходим с явной ошибкой вместо
    # зависания без интерфейса.
    # ВАЖНО: раньше здесь было «[[ ! -t 0 && -z "$INPUT_TTY" ]]», но INPUT_TTY
    # сам вычисляется через «-t 0», поэтому при запуске через «su -c» из
    # konsole условие было ложным и управление всё равно уходило в die/.
    if [[ "$INTERACTIVE" != "1" ]]; then
        printf '%s ERROR: Интерактивное меню недоступно: stdin не является терминалом.\n' "$(date '+%F %T')" >&2
        printf 'Запустите скрипт из терминала или передайте действие аргументом, например: sudo bash %s export --yes\n' "${BASH_SOURCE[0]}" >&2
        log "ERROR: Interactive menu requested without a TTY (stdin=$(readlink -f /proc/self/fd/0 2>/dev/null || echo unknown)) — refusing to hang."
        return 3
    fi

    # ── Индикатор доступности пакетных инструментов в шапке меню ────────────
    # Если rpm/apt отсутствуют, экспорт/импорт/CryptoPro не смогут работать.
    # Пользователь должен видеть это ДО выбора пункта, а не получать «мёртвое»
    # окно после нажатия цифры.
    PKG_TOOLS_STATUS=""
    if have_cmd rpm && { have_cmd apt-get || have_cmd epm; }; then
        PKG_TOOLS_STATUS="${GREEN}rpm + пакетный менеджер ✓${NC}"
    else
        local _pt_missing=""
        have_cmd rpm || _pt_missing+="rpm "
        { have_cmd apt-get || have_cmd epm; } || _pt_missing+="apt-get/epm "
        PKG_TOOLS_STATUS="${RED}нет ${_pt_missing% } ✗ (экспорт/импорт будут недоступны)${NC}"
    fi

    while true; do
        show_menu

        local choice=""
        # v2.0.6: промпт печатается ОТДЕЛЬНО (printf), затем read БЕЗ -p.
        # Причина: bash при «read -p'...'» пишет промпт в stderr только когда
        # stdin — TTY И stdout тоже TTY; при запуске из konsole/su иногда
        # stdout оказывается не-TTY — и приглашение молча пропадало, окно
        # выглядело «зависшим». printf гарантированно виден всегда.
        # Читает read_user_input: stdin=TTY или /dev/tty (прямой
        # «read ... </dev/tty» после su давал EIO).
        printf '  Выбор [0-9]: '
        if ! read_user_input ""; then
            echo
            exit 0
        fi
        choice="$REPLY_OUT"

        choice="$(printf '%s' "$choice" | tr -d '\r\n ')"

        case "$choice" in
            1)
                if prepare_export 1; then
                    if ! do_export; then
                        step_warn "Экспорт завершился с ошибками."
                    fi
                fi
                pause_console
                ;;
            2)
                if prepare_export 0; then
                    if ! do_export; then
                        step_warn "Экспорт завершился с ошибками."
                    fi
                fi
                pause_console
                ;;
            3)
                if prepare_import_interactive; then
                    if ! do_import; then
                        step_warn "Импорт завершился с ошибками или отменён."
                    fi
                fi
                pause_console
                ;;
            4)
                if prepare_import_offline; then
                    if ! do_import; then
                        step_warn "Офлайн-импорт завершился с ошибками или отменён."
                    fi
                fi
                pause_console
                ;;
            5)
                if prepare_crypto_interactive; then
                    if ! do_cryptopro_only; then
                        step_warn "Установка CryptoPro завершилась с ошибками."
                    fi
                fi
                pause_console
                ;;
            6)
                if ! do_verify; then
                    step_warn "Проверка бэкапа не пройдена."
                fi
                pause_console
                ;;
            7)
                if ! fetch_deps_cache; then
                    step_warn "Скачивание офлайн-кэша завершилось с ошибками."
                fi
                pause_console
                ;;
            8)
                system_summary
                pause_console
                ;;
            9)
                create_desktop_shortcut
                pause_console
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

# ─── Точка входа ──────────────────────────────────────────────────────────────
# v2.0.5-fix (итоговая схема логирования): НИКАКИХ обёрток над всем скриптом.
# История проблем:
#   a) exec > >(sed|tee >&3) 2>&1 + exec 3>&1 — перехват дескрипторов ломал
#      чтение с терминала (read → EIO), окно «висело» при пишущемся логе;
#   b) bash "$SELF" | sed | tee — дочерний процесс писал только в pipe, tee
#      буферизовал поблочно: терминал молчал («окно висит, логи пишутся»),
#      плюс замок flock наследовался через fd 9 → «Другой экземпляр запущен».
# Правильно: интерактивный вывод идёт НАПРЯМУЮ в унаследованный TTY (stdout/
# stderr не редиректятся вообще), stdin не трогается. В журнале остаются все
# служебные строки log()/step_*/info/warn (они пишутся в $LOG_FILE напрямую).
# Неинтерактивный запуск (CLI из cron/GUI-обёртки без TTY) — весь вывод в лог.
if [[ "${ALT_SYNC_LOGPIPE:-}" != "1" ]] && [[ "$INTERACTIVE" != "1" ]]; then
    # Неинтерактивно: stdout+stderr только в лог (в файле нет ANSI-кодов,
    # т.к. цвета определены пусто для не-TTY stdout).
    exec >> "$LOG_FILE" 2>&1
fi

main "$@"