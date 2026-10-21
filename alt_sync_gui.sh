#!/usr/bin/env bash
set -u

GUI_VERSION="3.1"
APP_TITLE="Alt Sync — слепок системы v$GUI_VERSION"

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" 2>/dev/null && pwd)" || SELF_DIR="$PWD"
[[ "$SELF" != /* ]] && SELF="$SELF_DIR/$SELF"

BACKEND_SCRIPT="${ALT_SYNC_BACKEND:-$SELF_DIR/alt_sync.sh}"

GUI_LOG_DIR="$SELF_DIR/logs"
mkdir -p "$GUI_LOG_DIR" 2>/dev/null || true
if [[ ! -w "$GUI_LOG_DIR" ]] || ! : >> "$GUI_LOG_DIR/.write_test" 2>/dev/null; then
    GUI_LOG_DIR="/tmp/alt-sync-gui-logdir"
    mkdir -p "$GUI_LOG_DIR" 2>/dev/null || true
else
    rm -f "$GUI_LOG_DIR/.write_test" 2>/dev/null || true
fi
GUI_TRACE="$GUI_LOG_DIR/alt_sync_gui_$(date +%Y%m%d_%H%M%S)_$$.trace"
GUI_LAST="$GUI_LOG_DIR/alt_sync_gui.last.log"
exec 2> >(tee -a "$GUI_TRACE" "$GUI_LAST" >&2)

glog() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }

gui_die() {
    glog "FATAL: $1"
    exit "${2:-3}"
}

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    for _d in $( { command -v who >/dev/null 2>&1 && who 2>/dev/null | awk '{print $NF}' | tr -d '()' | grep -E '^:[0-9]+'; printf ':0\n:1'; } 2>/dev/null | sort -u ); do
        [[ -e "/tmp/.X11-unix/X${_d#:}" ]] || continue
        [[ -z "${XAUTHORITY:-}" && -r "$HOME/.Xauthority" ]] && export XAUTHORITY="$HOME/.Xauthority"
        export DISPLAY="$_d"
        glog "DISPLAY определён автоматически: $_d"
        break
    done
fi
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    gui_die "нет графической сессии (DISPLAY/WAYLAND_DISPLAY пусты).
Варианты:
  1) запустить из терминала KDE:  bash $SELF
  2) передать вручную:            DISPLAY=:0 bash $SELF
  3) CLI без GUI:                 sudo bash $BACKEND_SCRIPT export --yes
След запуска: $GUI_TRACE" 3
fi

have() { [[ -n "${1:-}" && -x "${1:-}" ]] || command -v -- "$1" >/dev/null 2>&1; }

resolve_widget_path() {
    local p
    p=$(command -v -- "$WIDGET_BIN" 2>/dev/null) || p=""
    printf '%s' "$p"
}

detect_environment() {
    local env="" de session
    IFS=';' read -ra _desks <<< "${XDG_CURRENT_DESKTOP:-}"
    for de in "${_desks[@]:-}"; do
        case "$(printf '%s' "$de" | tr '[:upper:]' '[:lower:]')" in
            *plasma*|*kde*) env="plasma"; break ;;
            *gnome*|*unity*) env="gnome"; break ;;
            *xfce*) env="xfce"; break ;;
            *cinnamon*) env="cinnamon"; break ;;
            *mate*) env="mate"; break ;;
            *lxqt*) env="lxqt"; break ;;
            *lxde*) env="lxde"; break ;;
        esac
    done
    if [[ -z "$env" ]]; then
        session="$(printf '%s' "${DESKTOP_SESSION:-}" | tr '[:upper:]' '[:lower:]')"
        case "$session" in
            *plasma*|*kde*) env="plasma" ;;
            *gnome*) env="gnome" ;;
            *xfce*) env="xfce" ;;
            *cinnamon*) env="cinnamon" ;;
            *mate*) env="mate" ;;
            *lxqt*) env="lxqt" ;;
            *lxde*) env="lxde" ;;
        esac
    fi
    if [[ -z "$env" ]] && have pgrep; then
        pgrep -x kded5 >/dev/null 2>&1 && env="plasma"
        [[ -z "$env" ]] && pgrep -x plasmashell >/dev/null 2>&1 && env="plasma"
        [[ -z "$env" ]] && pgrep -x gnome-shell >/dev/null 2>&1 && env="gnome"
        [[ -z "$env" ]] && pgrep -x xfce4-session >/dev/null 2>&1 && env="xfce"
    fi
    printf '%s' "${env:-unknown}"
}

ENV_NAME="$(detect_environment)"
IS_KDE=0
case "$ENV_NAME" in plasma|lxqt) IS_KDE=1 ;; esac

links_pango() {
    local bin out
    bin="$(command -v "$1" 2>/dev/null)" || { printf 'unknown'; return; }
    have ldd || { printf 'unknown'; return; }
    out="$(ldd "$bin" 2>/dev/null)" || { printf 'unknown'; return; }
    if printf '%s' "$out" | grep -Eq 'libpango|libgtk'; then printf 'yes'; else printf 'no'; fi
}

widget_ok() { command -v "$1" >/dev/null 2>&1; }

pick_widget_order() {
    case "$ENV_NAME" in
        plasma|lxqt)    printf 'kdialog yad zenity qarma' ;;
        gnome|cinnamon) printf 'zenity yad qarma kdialog' ;;
        xfce|mate|lxde) printf 'zenity yad kdialog qarma' ;;
        *)              printf 'yad zenity kdialog qarma' ;;
    esac
}

WIDGET_BIN=""
MARKUP_OK=0
CARD_STYLE="plain"

DETECT_JSON="$SELF_DIR/detect_desktop.report.json"
used_report=0
if [[ -f "$DETECT_JSON" ]] \
   && (( $(date +%s) - $(stat -c %Y "$DETECT_JSON" 2>/dev/null || stat -f %m "$DETECT_JSON" 2>/dev/null || echo 0) < 86400 )); then
    flat_json=$(tr -d '\n' <"$DETECT_JSON" 2>/dev/null)
    r_widget=$(printf '%s' "$flat_json" | sed -nE 's/.*"recommendation"[^}]*"widget"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
    r_markup=$(printf '%s' "$flat_json" | sed -nE 's/.*"recommendation"[^}]*"markup_supported"[[:space:]]*:[[:space:]]*(true|false).*/\1/p')
    r_style=$(printf '%s' "$flat_json" | sed -nE 's/.*"recommendation"[^}]*"card_style"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
    if [[ -n "$r_widget" && "$r_widget" != "none" ]] && widget_ok "$r_widget"; then
        r_path=$(printf '%s' "$flat_json" | sed -nE 's/.*"'"$r_widget"'":\{[^}]*"path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')
        if [[ -n "$r_path" && -x "$r_path" ]]; then WIDGET_BIN="$r_path"; else WIDGET_BIN="$r_widget"; fi
        [[ "$r_markup" == "true" ]] && MARKUP_OK=1 || MARKUP_OK=0
        [[ "$r_style" == "pango" ]] && CARD_STYLE="pango" || CARD_STYLE="plain"
        used_report=1
        glog "виджет по отчёту detect_desktop.sh: $WIDGET_BIN (markup=$MARKUP_OK, card=$CARD_STYLE)"
    fi
    unset r_widget r_markup r_style flat_json
fi

if (( ! used_report )); then
    for c in $(pick_widget_order); do
        if widget_ok "$c"; then
            _wp=$(command -v -- "$c" 2>/dev/null) || _wp=""
            WIDGET_BIN="${_wp:-$c}"; break; fi
    done
    if [[ -n "$WIDGET_BIN" ]]; then
        case "${WIDGET_BIN##*/}" in
            kdialog)               MARKUP_OK=0 ;;
            yad|matedialog|zentry) MARKUP_OK=1 ;;
            zenity|qarma)
                mp="$(links_pango "$WIDGET_BIN")"
                if [[ "$mp" == "yes" && $IS_KDE -eq 0 ]]; then MARKUP_OK=1; else MARKUP_OK=0; fi ;;
            *)                     MARKUP_OK=0 ;;
        esac
        [[ "${ALT_SYNC_CARD_PLAIN:-0}" == "1" ]] && MARKUP_OK=0
        [[ "${ALT_SYNC_CARD_PANGO:-0}" == "1" ]] && MARKUP_OK=1
        (( MARKUP_OK )) && CARD_STYLE="pango" || CARD_STYLE="plain"
        glog "виджет определён локально: $WIDGET_BIN (среда=$ENV_NAME, card=$CARD_STYLE)"
    fi
fi

strip_markup() {
    local s="$1"
    while [[ "$s" =~ "<"[a-zA-Z/\!][^">"]*">" ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
    s="${s//&lt;/<}"; s="${s//&gt;/>}"; s="${s//&amp;/&}"
    printf '%b' "${s//$'\n'/\\n}"
}

safe_text() {
    local t="${1:-}" sep="${2:- }"
    (( MARKUP_OK )) || t="$(strip_markup "$t")"
    printf '%s' "${t//$'\n'/$sep}"
}

esc_pango() { printf '%s' "${1//&/&amp;}" | sed 's/</\&lt;/g;s/>/\&gt;/g'; }

desktop_notify() {
    local msg; msg="$(safe_text "$1" ' ')"
    glog "notify: $msg"
    printf '[Alt Sync] %s\n' "$msg" >&2
}

GUI_CHECK_ARGS=()
GUI_EXTRA_ARGS=()

GUI_DIALOG_LOCKDIR=""
GUI_DIALOG_LOCK_HELD=""

dialog_lock_acquire() {
    [[ -n "${_DLOCK_OWNED:-}" ]] && return 0
    local waited=0 owner
    GUI_DIALOG_LOCKDIR="${TMPDIR:-/tmp}/alt-sync-gui-dialog.$(id -u).lock"
    while ! mkdir "$GUI_DIALOG_LOCKDIR" 2>/dev/null; do
        if (( waited == 0 )); then
            owner=$(cat "$GUI_DIALOG_LOCKDIR/pid" 2>/dev/null)
            if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
                rm -rf "$GUI_DIALOG_LOCKDIR" 2>/dev/null || true
                continue
            fi
            printf '[Alt Sync] Жду ответа в другом открытом окне…\n' >&2
        fi
        sleep 1; waited=$((waited+1))
        if (( waited >= 120 )); then
            owner=$(cat "$GUI_DIALOG_LOCKDIR/pid" 2>/dev/null)
            if [[ -z "$owner" ]] || ! kill -0 "$owner" 2>/dev/null; then
                rm -rf "$GUI_DIALOG_LOCKDIR" 2>/dev/null || true
                continue
            fi
            glog "внимание: диалог-лок удерживает живой процесс $owner более 120 с — изымаю лок"
            rm -rf "$GUI_DIALOG_LOCKDIR" 2>/dev/null || true
            continue
        fi
    done
    printf '%s\n' "$$" >"$GUI_DIALOG_LOCKDIR/pid" 2>/dev/null || true
    _DLOCK_OWNED=1
    return 0
}

dialog_lock_release() {
    if [[ -n "${_DLOCK_OWNED:-}" ]]; then
        if [[ -n "${GUI_DIALOG_LOCKDIR:-}" ]] \
           && [[ "$(cat "$GUI_DIALOG_LOCKDIR/pid" 2>/dev/null)" == "$$" ]]; then
            rm -rf "$GUI_DIALOG_LOCKDIR" 2>/dev/null || true
        fi
        _DLOCK_OWNED=""
    fi
}

gui_dialog() {
    local kind="$1"; shift
    local text="${1:-}"
    local title="${GUI_DIALOG_TITLE:-$APP_TITLE}"
    [[ -n "$WIDGET_BIN" ]] || { printf '%s\n' "$(strip_markup "$text")" >&2; return 1; }

    if [[ "$kind" == "notify" ]]; then
        desktop_notify "$text"
        return 0
    fi

    dialog_lock_acquire || return 1
    local rc=0 out=""
    if [[ "$kind" == "checklist" ]]; then
        GUI_CHECK_ARGS=("$@")
    else
        GUI_EXTRA_ARGS=("$@")
    fi
    out=$(_gui_dialog_run "$kind" "$text" "$title") || rc=$?
    GUI_EXTRA_ARGS=()
    dialog_lock_release
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return $rc
}

_gui_dialog_run() {
    local kind="$1" text="$2" title="$3"
    case "${WIDGET_BIN##*/}" in
        kdialog)
            local kt; kt="$(strip_markup "${text//$'\n'/\\n}")"
            case "$kind" in
                info)       "$WIDGET_BIN" --title "$title" --information "$kt" ;;
                warning)    "$WIDGET_BIN" --title "$title" --sorry "$kt" ;;
                error)      "$WIDGET_BIN" --title "$title" --error "$kt" ;;
                question)   "$WIDGET_BIN" --title "$title" --yesno "$kt" "${GUI_EXTRA_ARGS[@]}" ; return $? ;;
                entry)      "$WIDGET_BIN" --title "$title" --inputbox "$kt" "${GUI_ENTRY_DEFAULT:-}" ; return $? ;;
                password)   "$WIDGET_BIN" --title "$title" --password "$kt" ; return $? ;;
                viewfile)   "$WIDGET_BIN" --title "$title" --txtbox "$text" ; return $? ;;
                list)
                    local _i=0 _it _tagged=()
                    if (( ${#GUI_LIST_ITEMS[@]} >= 2 )) && [[ "${GUI_LIST_ITEMS[0]}" =~ ^[0-9]+$ ]]; then
                        _tagged=("${GUI_LIST_ITEMS[@]}")
                    else
                        for _it in "${GUI_LIST_ITEMS[@]}"; do
                            _tagged+=( "$((_i/2+1))" "$_it" ); _i=$((_i+1))
                        done
                        if (( ${#_tagged[@]} != ${#GUI_LIST_ITEMS[@]}*2 )); then
                            _tagged=(); _i=0
                            for _it in "${GUI_LIST_ITEMS[@]}"; do
                                _tagged+=( "$((_i+1))" "$_it" ); _i=$((_i+1))
                            done
                        fi
                    fi
                    "$WIDGET_BIN" --title "$title" --menu "$kt" "${_tagged[@]}" ; return $? ;;
                checklist)  "$WIDGET_BIN" --title "$title" --separate-output --checklist \
                                "$kt" "${GUI_CHECK_ARGS[@]}" ; return $? ;;
                *) return 1 ;;
            esac
            return 0 ;;
        yad)
            case "$kind" in
                info)     yad --title "$title" --text="$(safe_text "$text")" --image="dialog-information" \
                              --button="Понятно:0" --width=560 --center --wrap ;;
                warning)  yad --title "$title" --text="$(safe_text "$text")" --image="dialog-warning" \
                              --button="Закрыть:0" --width=560 --center --wrap ;;
                error)    yad --title "$title" --text="$(safe_text "$text")" --image="dialog-error" \
                              --button="Закрыть:0" --width=620 --center --wrap ;;
                question) yad --title "$title" --text="$(safe_text "$text")" --image="dialog-question" \
                              --button="Да:0" --button="Нет:1" --width=560 --center --wrap ; return $? ;;
                entry)    yad --title "$title" --text="$(safe_text "$text")" --entry --entry-text="${GUI_ENTRY_DEFAULT:-}" \
                              --button="ОК:0" --button="Отмена:1" --width=480 --center ; return $? ;;
                password) yad --title "$title" --password --prompt="$(safe_text "$text")" --hide-entry --width=430 --center ; return $? ;;
                list)     yad --title "$title" --text="$(safe_text "$text")" --list --radiolist --height=420 \
                              --column="Выбор" --column="Действие" "${GUI_LIST_ITEMS[@]}" \
                              --button="Выполнить:0" --button="Выход:1" --width=640 --center ; return $? ;;
                checklist) yad --title "$title" --text="$(safe_text "${GUI_CHECK_ARGS[0]:-$text}")" \
                              --list --checklist --height=380 --separator=$'\t' \
                              --column="${GUI_CHECK_ARGS[1]:-Включить}" --column="${GUI_CHECK_ARGS[2]:-Компонент}" \
                              "${GUI_CHECK_ARGS[@]:3}" \
                              --button="Далее:0" --button="Отмена:1" --width=640 --center ; return $? ;;
                viewfile) yad --title "$title" --text-info --filename="$text" --wrap \
                              --button="Закрыть:0" --width=900 --height=600 --center ; return $? ;;
                *) return 1 ;;
            esac
            return 0 ;;
        qarma)
            case "$kind" in
                info)     qarma --zenity-compat --title "$title" --info --text="$(safe_text "$text")" ;;
                warning)  qarma --zenity-compat --title "$title" --warning --text="$(safe_text "$text")" ;;
                error)    qarma --zenity-compat --title "$title" --error --text="$(safe_text "$text")" ;;
                question) qarma --zenity-compat --title "$title" --question --text="$(safe_text "$text")" ; return $? ;;
                entry)    qarma --zenity-compat --title "$title" --entry --entry-text="${GUI_ENTRY_DEFAULT:-}" \
                              --text="$(safe_text "$text")" ; return $? ;;
                password) qarma --password --title "$title" --prompt="$(safe_text "$text")" ; return $? ;;
                list)     qarma --zenity-compat --title "$title" --list --radiolist --text="$(safe_text "$text")" \
                              --column="Действие" "${GUI_LIST_ITEMS[@]}" ; return $? ;;
                checklist) qarma --zenity-compat --title "$title" --list --checklist \
                              --text="$(safe_text "${GUI_CHECK_ARGS[0]:-$text}")" \
                              --column="${GUI_CHECK_ARGS[1]:-Включить}" --column="${GUI_CHECK_ARGS[2]:-Компонент}" \
                              "${GUI_CHECK_ARGS[@]:3}" ; return $? ;;
                viewfile) qarma --title "$title" --text-info --filename="$text" ; return $? ;;
                *) return 1 ;;
            esac
            return 0 ;;
        *)
            case "$kind" in
                info)     "$WIDGET_BIN" --title "$title" --info --text="$(safe_text "$text")" ;;
                warning)  "$WIDGET_BIN" --title "$title" --warning --text="$(safe_text "$text")" ;;
                error)    "$WIDGET_BIN" --title "$title" --error --text="$(safe_text "$text")" ;;
                question) "$WIDGET_BIN" --title "$title" --question --text="$(safe_text "$text")" ; return $? ;;
                entry)    "$WIDGET_BIN" --title "$title" --entry --entry-text="${GUI_ENTRY_DEFAULT:-}" \
                              --text="$(safe_text "$text")" ; return $? ;;
                password) "$WIDGET_BIN" --title "$title" --password --prompt="$(safe_text "$text")" ; return $? ;;
                list)     "$WIDGET_BIN" --title "$title" --list --radiolist --text="$(safe_text "$text")" \
                              --column="Действие" "${GUI_LIST_ITEMS[@]}" ; return $? ;;
                checklist) "$WIDGET_BIN" --title "$title" --list --checklist \
                              --text="$(safe_text "${GUI_CHECK_ARGS[0]:-$text}")" \
                              --column="${GUI_CHECK_ARGS[1]:-Включить}" --column="${GUI_CHECK_ARGS[2]:-Компонент}" \
                              "${GUI_CHECK_ARGS[@]:3}" ; return $? ;;
                viewfile) "$WIDGET_BIN" --title "$title" --text-info --filename="$text" --width=860 --height=560 ; return $? ;;
                *) return 1 ;;
            esac
            return 0 ;;
    esac
}

ACTIONS=(
    "Экспорт эталона (с докачкой RPM из сети)"
    "Экспорт эталона (только локальные RPM, офлайн)"
    "Импорт на копию железа (клонирование по слепку)"
    "Импорт полностью офлайн (без сети)"
    "Только CryptoPro + дополнительные пакеты"
    "Проверить целостность бэкапа (без изменений системы)"
    "Скачать компоненты в офлайн-кэш deps-rpm (нужен интернет)"
    "Открыть последний отчёт"
    "Открыть папку бэкапа"
)

map_action() {
    case "$1" in
        "Экспорт эталона (с докачкой RPM из сети)")          printf 'export|noconfirm|Экспорт эталона' ; return ;;
        "Экспорт эталона (только локальные RPM, офлайн)")    printf 'export-offline|noconfirm|Экспорт эталона (офлайн)' ; return ;;
        "Импорт полностью офлайн (без сети)")               printf 'import-offline|confirm|Офлайн-импорт слепка' ; return ;;
        "Импорт на копию железа (клонирование по слепку)")  printf 'import|confirm|Импорт слепка (клонирование)' ; return ;;
        "Только CryptoPro + дополнительные пакеты")          printf 'cryptopro|noconfirm|Установка CryptoPro' ; return ;;
        "Проверить целостность бэкапа (без изменений системы)") printf 'verify|noconfirm|Проверка целостности бэкапа' ; return ;;
        "Скачать компоненты в офлайн-кэш deps-rpm (нужен интернет)") printf 'fetch-deps|noconfirm|Загрузка компонентов в офлайн-кэш' ; return ;;
        "Открыть последний отчёт")                           printf 'report|noconfirm|Отчёт' ; return ;;
        "Открыть папку бэкапа")                              printf 'backupdir|noconfirm|Папка бэкапа' ; return ;;
    esac
    printf ''
}

detect_default_user() {
    local u=""
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && u="$SUDO_USER"
    [[ -z "$u" ]] && u=$(awk -F: '$3>=1000 && $3<65534 && $1!="nobody"{print $1; exit}' /etc/passwd 2>/dev/null)
    [[ -z "$u" ]] && u=$(logname 2>/dev/null || true)
    printf '%s' "$u"
}

KD_FEAT="none"
kd_detect_features() {
    [[ "$KD_FEAT" != "none" ]] && return 0
    local h; h=$("$WIDGET_BIN" --help 2>&1) || true
    KD_FEAT=""
    grep -q -- '--checklist'   <<<"$h" && KD_FEAT+="checklist "
    if [[ "${WIDGET_BIN##*/}" == kdialog ]]; then
        KD_FEAT+="progressbar "
    else
        grep -q -- '--progress' <<<"$h" && KD_FEAT+="progressbar "
    fi
    [[ -z "$KD_FEAT" ]] && KD_FEAT="basic"
    KD_FEAT="${KD_FEAT% }"
}

export_opts_window() {
    local user_def="$1" net=0 moz=0 checks="" r u out_f

    if [[ "${WIDGET_BIN:-}" == kdialog || "${WIDGET_BIN##*/}" == kdialog ]]; then
        kd_detect_features
        dialog_lock_acquire || return 1
        trap 'dialog_lock_release' RETURN
        out_f="$(mktemp "${TMPDIR:-/tmp}/alt_sync_opts.XXXXXX")" || return 1
        r=0
        "$WIDGET_BIN" --title "$APP_TITLE — Профиль" --inputbox \
$'Профиль какого пользователя включать в слепок?' "$user_def" >"$out_f" 2>/dev/null || r=$?
        (( r >= 2 )) && { rm -f "$out_f"; return 1; }
        u=$(<"$out_f"); rm -f "$out_f"
        u="${u//[[:space:]]/}"; [[ -n "$u" ]] || u="$user_def"

        r=0
        "$WIDGET_BIN" --title "$APP_TITLE — Пароли Wi-Fi" --yesno \
$'Включать ли в слепок ПАРОЛИ WI-FI?\n\nЕсли «Да»: в файл слепка попадут названия беспроводных сетей и ключи к ним (NetworkManager) — на другой машине эти сети подключатся автоматически.\nЕсли «Нет»: ключи сетей сохраняться НЕ будут.\n\n(Базовый набор — список RPM, /etc, принтеры, sudoers — сохраняется всегда.)' >/dev/null 2>&1 || r=$?
        (( r >= 2 )) && return 1
        (( r == 0 )) && net=1

        r=0
        "$WIDGET_BIN" --title "$APP_TITLE — Профиль Firefox" --yesno \
$'Включать ли в слепок ПРОФИЛЬ БРАУЗЕРА Firefox (~/.mozilla)?\n\nЕсли «Да»: сохранятся cookies, история, закладки и пароли, которые браузер помнит за вас.\nЕсли «Нет»: профиль Firefox сохранён НЕ будет.\n\n(Базовый набор — список RPM, /etc, принтеры, sudoers — сохраняется всегда.)' >/dev/null 2>&1 || r=$?
        (( r >= 2 )) && return 1
        (( r == 0 )) && moz=1

        printf '%s|%s|%s' "$u" "$net" "$moz"
        return 0
    fi

    if have "$WIDGET_BIN" && "$WIDGET_BIN" --help 2>&1 | grep -q -- '--checklist'; then
        checks=$(GUI_DIALOG_TITLE="$APP_TITLE — Что включить сверх базового набора" gui_dialog checklist \
"Bазовый набор (RPM-лист, /etc, принтеры, sudoers) сохраняется ВСЕГДА.
Здесь — только доп. СЕКРЕТНЫЕ компоненты, их отметьте галками:" \
            "Вкл." "Что сохраняется и зачем" \
            FALSE "Пароли Wi-Fi (NetworkManager) — ключи беспроводных сетей для переноса" \
            FALSE "Профиль Firefox (~/.mozilla) — cookies, история, пароли браузера") || return 1
        [[ "$checks" == *"Пароли Wi-Fi"* || "$checks" == *"Wi-Fi"* ]] && net=1
        [[ "$checks" == *"Firefox"* || "$checks" == *"mozilla"* ]] && moz=1
    else
        GUI_DIALOG_TITLE="$APP_TITLE"
        gui_dialog question "Включить в слепок ПАРОЛИ Wi-Fi (NetworkManager)?
Это секретные ключи сетей — они попадут в файл слепка." && net=1
        gui_dialog question "Включить в слепок профиль FIREFOX (~/.mozilla)?
Cookies, история и сохранённые браузером пароли." && moz=1
    fi
    GUI_DIALOG_TITLE="$APP_TITLE — Подтверждение запуска"
    u=$(gui_entry_ok_cancel "Имя пользователя, чей профиль включать в слепок:" "$user_def") || return 1
    u="${u//[[:space:]]/}"
    printf '%s|%s|%s' "${u:-$user_def}" "$net" "$moz"
}

view_report() {
    local rep
    rep=$(ls -1t "$SELF_DIR"/logs/alt_sync_report_*.txt "$SELF_DIR"/alt_sync_report_*.txt 2>/dev/null | head -1)
    if [[ -z "$rep" ]]; then
        gui_dialog warning "Отчётов пока нет — сначала выполните экспорт или импорт."
        return
    fi
    GUI_DIALOG_TITLE="$APP_TITLE — Отчёт" gui_dialog viewfile "$rep"
}

view_backup_dir() {
    local bdir="$SELF_DIR/alt_backup"
    [[ -d "$bdir" ]] || bdir="$SELF_DIR"
    if have dolphin; then dolphin "$bdir" >/dev/null 2>&1 &
    elif have xdg-open; then xdg-open "$bdir" >/dev/null 2>&1 &
    else gui_dialog info "Папка бэкапа: $bdir"; fi
}

PP_PID=""
PP_WRITER=""
PP_WAITER=""
PP_FIFO=""
PP_CANCEL_RC=""
PP_MODE=""
PP_KD_UUID=""
GUI_CANCEL_FLAG=""
GUI_USER_CANCEL=""
PP_HEALTH=""
KD_LAUNCH_LOG=""

cancel_requested() {
    [[ -n "${GUI_USER_CANCEL:-}" && -e "$GUI_USER_CANCEL" ]] && return 0
    [[ -n "${GUI_CANCEL_FLAG:-}" && -e "$GUI_CANCEL_FLAG" ]] && return 0
    return 1
}

mark_cancel() {
    [[ -n "${GUI_CANCEL_FLAG:-}" ]] && : >"$GUI_CANCEL_FLAG" 2>/dev/null || true
    [[ -n "${GUI_USER_CANCEL:-}" ]] && : >"$GUI_USER_CANCEL" 2>/dev/null || true
}

parse_log_tail() {
    local raw cur_step step="" pct="" base="" lastline=""
    raw=$(cat)
    cur_step=$(printf '%s\n' "$raw" | grep -aE 'PROGRESS\|step=[0-9]+\|[0-9]+' | tail -1)
    local msteps=""
    if [[ -n "$cur_step" ]]; then
        local rest=${cur_step#*step=} _sn _r _sm _r2 _s3 _sp _sname
        _sn=${rest%%|*}; _r=${rest#*|}
        _sm=${_r%%|*}; _r2=${_r#*|}
        _s3=${_r2%%|*}; _sp=${_r2#*|}
        _sname=${_sp#*|}; _sp=${_sp%%|*}
        [[ "$_s3" == pct=* ]] && { _sname="$_sp"; _sp="$_s3"; _s3=""; }
        _sp=${_sp#pct=}
        step="Шаг ${_sn} из ${_sm}: ${_sname}"
        base="$_sp"
        msteps="$_sm"
    fi
    local dline dpct=""
    dline=$(printf '%s\n' "$raw" | grep -aE 'PROGRESS\|detail\|' | tail -1)
    if [[ -n "$dline" ]]; then
        dpct=$(printf '%s' "$dline" | grep -oE 'pct=[0-9]{1,3}' | tail -1 | tr -dc '0-9')
        if [[ -n "$base" && -n "$dpct" ]]; then
            [[ "$msteps" =~ ^[0-9]+$ ]] && (( msteps > 0 )) || msteps=7
            pct=$(awk -v b="$base" -v d="$dpct" -v m="$msteps" 'BEGIN{p=b+d/100*(100.0/m); if(p>99)p=99; printf "%d", p}')
        fi
    fi
    [[ -n "${pct:-}" ]] || pct="${base:-}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=""
    if [[ -z "$pct" ]]; then
        pct=$(printf '%s\n' "$raw" | grep -aoE '\(([0-9]{1,3})%\)' | tail -1 | tr -dc '0-9')
    fi
    lastline=$(printf '%s\n' "$raw" \
        | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\[K//g' \
        | grep -avE '^[[:space:]]*$|PROGRESS\||Gtk-WARNING|GLib.*(CRITICAL|WARNING)|^INIT: alt_sync' \
        | tail -1 \
        | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} //; s/^(\[[^]]*\])? *(INFO|OK|WARN|STEP|ERROR|FATAL|DEBUG|FAIL):? *//' \
        | sed -E 's/^(▶|✅|⚠️|❌|ℹ️) *//' \
        | cut -c1-120)
    printf '%s\n%s\n%s\n' "$step" "$pct" "$lastline"
}

build_card() {
    local label="$1" tstart="$2" t0="$3" step="$4" pct="$5" lastline="$6" logf="$7"
    local el h m s tstr
    el=$(( $(date +%s) - t0 )); h=$((el/3600)); m=$(( (el%3600)/60 )); s=$((el%60))
    if (( h > 0 )); then printf -v tstr '%d:%02d:%02d' "$h" "$m" "$s"
    else printf -v tstr '%02d:%02d' "$m" "$s"; fi
    if (( MARKUP_OK )); then
        local out="<span size=\"x-large\" weight=\"bold\">$(esc_pango "▶ $label")</span>"$'\n'
        out+="<span size=\"small\">🕐 ${tstart} · ⏱ ${tstr}</span>"$'\n\n'
        if [[ -n "$step" ]]; then
            out+="<b>$(esc_pango "$step")</b>"
            [[ -n "$pct" ]] && out+=" — выполнено ${pct}%"
            out+=$'\n\n'
        else
            out+="Подготовка окружения…"$'\n\n'
        fi
        out+="<b>Текущее действие:</b>$'\n'"
        out+="$(esc_pango "${lastline:-ожидание данных из лога…}")"$'\n\n'
        out+="<span size=\"small\">Живой лог: $(esc_pango "$logf")</span>"
        printf '%s' "$out"
    else
        local npct="${pct:-0}" bar="" i
        [[ "$npct" =~ ^[0-9]+$ ]] || npct=0
        (( npct > 100 )) && npct=100
        for ((i=0; i<20; i++)); do (( i*5 < npct )) && bar+="█" || bar+="░"; done
        local out="▶ ${label}"$'\n'
        out+="🕐 ${tstart} · ⏱ ${tstr}"$'\n\n'
        if [[ -n "$step" ]]; then
            out+="${step}"$'\n'
            out+="[${bar}] ${npct}%"$'\n\n'
        else
            out+="Подготовка окружения…"$'\n\n'
        fi
        out+="➤ Текущее действие:"$'\n'
        out+="${lastline:-ожидание данных из лога…}"$'\n\n'
        out+="Лог: ${logf}"
        printf '%s' "$out"
    fi
}

pp_writer() {
    local fifo="$1" label="$2" logf="$3" t0="$4" tstart="$5" wpid="$6" bepid="$7"
    local raw parsed step pct lastline card rc _tick=0 prev=""
    while :; do
        cancel_requested && return 0
        kill -0 "$wpid" 2>/dev/null || return 0
        raw=$(tail -200 "$logf" 2>/dev/null)
        parsed=$(printf '%s\n' "$raw" | parse_log_tail)
        step=$(printf '%s\n' "$parsed" | sed -n 1p)
        pct=$(printf '%s\n' "$parsed" | sed -n 2p)
        lastline=$(printf '%s\n' "$parsed" | sed -n 3p)
        card=$(build_card "$label" "$tstart" "$t0" "$step" "$pct" "$lastline" "$logf")
        rc="${pct:-}"
        [[ "$rc" =~ ^[0-9]+$ ]] || rc=$(( (_tick * 3) % 90 + 5 ))
        (( rc > 99 )) && rc=99
        _tick=$((_tick + 1))
        if [[ "$card" != "$prev" ]] || (( _tick % 15 == 0 )); then
            prev="$card"
            local lines="${card//$'\r'/ }"
            printf '#%s\n%s\n' "${lines//$'\n'/\\n}" "$rc" >"$fifo" 2>/dev/null || return 0
        fi
        sleep 1
    done
}

progress_open() {
    local label="$1" logf="$2" bepid="$3" t0="$4" tstart="$5"
    PP_CANCEL_RC=""
    GUI_USER_CANCEL="$GUI_LOG_DIR/.user_cancel.$$"
    rm -f "$GUI_USER_CANCEL" 2>/dev/null || true

    if [[ "${WIDGET_BIN:-}" == kdialog || "${WIDGET_BIN##*/}" == kdialog ]]; then
        kd_detect_features
        if [[ "$KD_FEAT" != *progressbar* || "${GRAPHICS_OK:-}" == "no" ]]; then
            PP_MODE="kdmenu"
            GUI_USER_CANCEL="$GUI_LOG_DIR/.user_cancel.$$"
            rm -f "$GUI_USER_CANCEL" 2>/dev/null || true
            (
                _be="$bepid"; _logf="$logf"; _label="$label"; _t0="$t0"; _tstart="$tstart"
                _cardf="${TMPDIR:-/tmp}/alt_sync_kdmenu_card.$$"
                _draw() { tail -200 "$_logf" 2>/dev/null | parse_log_tail >"$_cardf"; }
                _kd() { "$WIDGET_BIN" --title "$APP_TITLE — $_label" "$@" >>"${KD_LAUNCH_LOG:-/dev/null}" 2>&1; }
                _fmt() {
                    local st pc ll card
                    st=$(sed -n 1p "$_cardf"); pc=$(sed -n 2p "$_cardf"); ll=$(sed -n 3p "$_cardf")
                    card=$(build_card "$_label" "$_tstart" "$_t0" "$st" "$pc" "$ll" "$_logf")
                    printf '%s' "${card//$'\n'/ }"
                }
                while :; do
                    kill -0 "$_be" 2>/dev/null || break
                    cancel_requested && break
                    _draw
                    _mrc=0; _sel=""
                    _sel="$(_kd --menu "$(printf '%s' "$(_fmt)")" \
                        upd "⟳ Обновить сейчас" cnl "✖ Отменить задачу")" || _mrc=$?
                    (( _mrc >= 2 )) && mark_cancel
                    [[ "$_sel" == cnl ]] && mark_cancel
                    cancel_requested && break
                    _w=0
                    _pause=15; [[ "${_sel:-}" == upd ]] && _pause=3
                    while (( _w < _pause )); do
                        kill -0 "$_be" 2>/dev/null || break
                        cancel_requested && break
                        sleep 1; _w=$((_w+1))
                    done
                done
                _draw
                if cancel_requested; then
                    "$WIDGET_BIN" --title "$APP_TITLE — $_label" --sorry \
                        "⛔ Задача «$_label» отменена. $(printf '%s' "$(_fmt)")" >/dev/null 2>&1 || true
                else
                    "$WIDGET_BIN" --title "$APP_TITLE — $_label" --sorry \
                        "✔ Задача «$_label» завершена. $(printf '%s' "$(_fmt)")" >/dev/null 2>&1 || true
                fi
                rm -f "$_cardf" 2>/dev/null || true
            ) &
            PP_WRITER=$!
            disown "$PP_WRITER" 2>/dev/null || true
            return 0
        fi
        have mkfifo || return 1
        PP_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/alt_sync_kdprog.XXXXXX")" || return 1
        mkfifo "$PP_FIFO" 2>/dev/null || { PP_FIFO=""; return 1; }
        dialog_lock_acquire || true
        KD_LAUNCH_LOG="${TMPDIR:-/tmp}/alt_sync_kd_launch.${ALT_SYNC_TASK_ID}.log"
        "$WIDGET_BIN" --title "$APP_TITLE" --progressbar "$label" 100 <"$PP_FIFO" >"$KD_LAUNCH_LOG" 2>&1 &
        PP_PID=$!; PP_CANCEL_RC=0
        exec 8<>"$PP_FIFO" 2>/dev/null || true
        pp_writer "$PP_FIFO" "$label" "$logf" "$t0" "$tstart" "$PP_PID" "$bepid" &
        PP_WRITER=$!
        disown "$PP_WRITER" 2>/dev/null || true
        (
            wait "$PP_PID" 2>/dev/null; _rc=$?
            [[ -s "$KD_LAUNCH_LOG" ]] && glog "stderr окна gauge: $(head -c 400 "$KD_LAUNCH_LOG" | tr '\n' ' ')"
            [[ "$_rc" == "0" ]] && mark_cancel
        ) &
        PP_WAITER=$!
        disown "$PP_WAITER" 2>/dev/null || true
        PP_MODE="fifo"
        return 0
    fi

    have mkfifo || return 1
    PP_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/alt_sync_prog.XXXXXX")" || return 1
    mkfifo "$PP_FIFO" 2>/dev/null || { PP_FIFO=""; return 1; }
    case "${WIDGET_BIN##*/}" in
        yad)
            yad --progress --title "$APP_TITLE" --width=680 --height=420 \
                --text="$label" --percentage=0 --listen --time-elapsed \
                --button="Отменить задачу:1" <"$PP_FIFO" >/dev/null 2>&1 &
            PP_PID=$!; PP_CANCEL_RC=1 ;;
        qarma)
            qarma --zenity-compat --title "$APP_TITLE" --progress --text "$label" --percentage 0 \
                <"$PP_FIFO" >/dev/null 2>&1 &
            PP_PID=$!; PP_CANCEL_RC=1 ;;
        zenity)
            if zenity --help 2>&1 | grep -q -- '--cancel-text'; then
                zenity --progress --title "$APP_TITLE" --text "$label" --percentage 0 \
                    --cancel-text "Отменить задачу" <"$PP_FIFO" >/dev/null 2>&1 &
                PP_CANCEL_RC=1
            else
                zenity --progress --title "$APP_TITLE" --text "$label" --percentage 0 --no-cancel \
                    <"$PP_FIFO" >/dev/null 2>&1 &
                PP_CANCEL_RC=""
            fi
            PP_PID=$! ;;
        *) rm -f "$PP_FIFO" 2>/dev/null || true; PP_FIFO=""; return 1 ;;
    esac
    exec 8<>"$PP_FIFO" 2>/dev/null || true
    pp_writer "$PP_FIFO" "$label" "$logf" "$t0" "$tstart" "$PP_PID" "$bepid" &
    PP_WRITER=$!
    disown "$PP_WRITER" 2>/dev/null || true
    (
        wait "$PP_PID" 2>/dev/null; _rc=$?
        [[ -n "$PP_CANCEL_RC" && "$_rc" == "$PP_CANCEL_RC" ]] && mark_cancel
    ) &
    PP_WAITER=$!
    disown "$PP_WAITER" 2>/dev/null || true
    PP_MODE="fifo"
    return 0
}

progress_close() {
    [[ "${PP_MODE:-}" == "kdmenu" && -n "${PP_WRITER:-}" ]] && \
        { pkill -P "$PP_WRITER" 2>/dev/null || true; }
    if [[ -n "${PP_FIFO:-}" ]]; then
        printf '#100\n100\n' >&8 2>/dev/null || true
        exec 8>&- 2>/dev/null || true
        rm -f "$PP_FIFO" 2>/dev/null || true
        PP_FIFO=""
    fi
    if [[ -n "${PP_WRITER:-}" ]]; then
        kill "$PP_WRITER" 2>/dev/null || true
        wait "$PP_WRITER" 2>/dev/null || true
        PP_WRITER=""
    fi
    if [[ -n "${PP_PID:-}" ]]; then
        local _w=0
        while kill -0 "$PP_PID" 2>/dev/null && (( _w < 5 )); do sleep 1; _w=$((_w+1)); done
        kill "$PP_PID" 2>/dev/null || true
        wait "$PP_PID" 2>/dev/null || true
        PP_PID=""
    fi
    if [[ -n "${PP_WAITER:-}" ]]; then { kill "$PP_WAITER" 2>/dev/null || true; PP_WAITER=""; }; fi
    if [[ -n "${PP_HEALTH:-}" ]]; then
        kill "$PP_HEALTH" 2>/dev/null || true
        wait "$PP_HEALTH" 2>/dev/null || true
        PP_HEALTH=""
    fi
    if [[ -n "${KD_LAUNCH_LOG:-}" ]]; then
        rm -f "$KD_LAUNCH_LOG" 2>/dev/null || true
        KD_LAUNCH_LOG=""
    fi
    if [[ "${PP_MODE:-}" == "kdmenu" ]]; then
        PP_FINAL_SHOWN=1
    else
        PP_FINAL_SHOWN=""
    fi
    PP_WRITER=""; PP_PID=""; PP_MODE=""
    [[ -n "${GUI_CANCEL_FLAG:-}" ]] && rm -f "$GUI_CANCEL_FLAG" 2>/dev/null || true
    [[ -n "${GUI_USER_CANCEL:-}" ]] && rm -f "$GUI_USER_CANCEL" 2>/dev/null || true
    GUI_CANCEL_FLAG=""
    return 0
}

BE_PID=""
cleanup() {
    local rc=$?
    [[ "${PP_MODE:-}" == "kdmenu" && -n "${PP_WRITER:-}" ]] && \
        { pkill -P "$PP_WRITER" 2>/dev/null || true; }
    [[ -n "${PP_WRITER:-}" ]] && kill "$PP_WRITER" 2>/dev/null || true
    [[ -n "${PP_PID:-}" ]] && kill "$PP_PID" 2>/dev/null || true
    [[ -n "${BE_PID:-}" ]] && kill "$BE_PID" 2>/dev/null || true
    rm -f "${ROOT_PW_TMP:-}" 2>/dev/null || true
    dialog_lock_release
    progress_close 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

ROOT_PW_TMP=""

gui_entry_ok_cancel() {
    local text="$1" def="${2:-}" out=""
    if [[ "${WIDGET_BIN:-}" == kdialog || "${WIDGET_BIN##*/}" == kdialog ]]; then
        GUI_DIALOG_TITLE="$APP_TITLE"
        out=$(GUI_ENTRY_DEFAULT="$def" gui_dialog entry "$text") || return 1
    else
        out=$(GUI_ENTRY_DEFAULT="$def" gui_dialog entry "$text") || return 1
    fi
    printf '%s' "$out"
}

gui_confirm_dangerous() {
    GUI_DIALOG_TITLE="$APP_TITLE — Подтверждение запуска"
    gui_dialog question "$1

Нажмите «Да», чтобы продолжить, или «Нет» для отмены." \
        --yes-label "Да, запустить" --no-label "Отмена"
}

BACKEND_DETECTED_VERSION=""
backend_version_gate() {
    local line bv maj min
    [[ "${ALT_SYNC_GUI_SKIP_VERSION_GATE:-}" == "1" ]] && return 0
    line=$(bash "$BACKEND_SCRIPT" --version 2>/dev/null | head -1) || line=""
    [[ "$line" =~ v([0-9]+)\.([0-9]+) ]] && bv="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}" || return 0
    maj="${bv%%.*}"; min="${bv#*.}"; min="${min%%.*}"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 0
    if (( maj > 1 )); then return 0; fi
    if (( maj == 1 && min >= 16 )); then return 0; fi
    BACKEND_DETECTED_VERSION="$bv"
    return 1
}

run_backend() {
    local cli="$1" label="$2" user="${3:-}" net="${4:-0}" moz="${5:-0}"

    if [[ ! -f "$BACKEND_SCRIPT" ]]; then
        gui_dialog error "Не найден alt_sync.sh рядом с GUI-скриптом.
Положите оба файла в одну папку или задайте ALT_SYNC_BACKEND=/путь/к/alt_sync.sh"
        return 1
    fi
    if ! backend_version_gate; then
        gui_dialog error "Обнаружена СТАРАЯ копия alt_sync.sh (версия ${BACKEND_DETECTED_VERSION:-<1.0.16}).
GUI v$GUI_VERSION требует бэкенд, поддерживающий --log-file/--cancel-flag.
Скопируйте ОБА файла из одного свежего источника в одну папку."
        return 1
    fi
    BACKEND_SCRIPT="$(cd "$(dirname "$BACKEND_SCRIPT")" 2>/dev/null && pwd)/$(basename "$BACKEND_SCRIPT")"
    if [[ $EUID -eq 0 ]]; then
        ALT_SYNC_NO_ESCALATE=1 ALT_SYNC_ELEVATED=1 \
            run_task_launch "$cli" "$label" "$user" "$net" "$moz"
        return $?
    fi
    if [[ "${ALT_SYNC_WAS_ELEVATED:-0}" == "1" ]]; then
        ALT_SYNC_NO_ESCALATE=1 ALT_SYNC_ELEVATED=1 \
            run_task_launch "$cli" "$label" "$user" "$net" "$moz"
        return $?
    fi

    if [[ $EUID -ne 0 && "${ALT_SYNC_FAKE_ROOT:-0}" != "1" \
        && "${ALT_SYNC_WRAPPER_PID:-}" != "$$" && "${ALT_SYNC_WAS_ELEVATED:-0}" != "1" ]]; then
        local orig_uid; orig_uid=$(id -u)
        [[ -f "$BACKEND_SCRIPT" ]] || BACKEND_SCRIPT="$SELF_DIR/alt_sync.sh"
        local wrapper=(bash "$SELF" --run-task "$cli" "$label" "${user:-}" "$net" "$moz" \
                       --elevated-marker "--task-id=${ALT_SYNC_TASK_ID:-$$}" \
                       "--gui-self=$SELF" "--backend=$BACKEND_SCRIPT")
        local wrc=0 priv_method=""
        if have sudo && sudo -n true 2>/dev/null; then priv_method="sudo (кэш)"; fi
        if [[ -z "$priv_method" ]] && have pkexec; then priv_method="pkexec"; fi
        if [[ -z "$priv_method" ]]; then
            gui_dialog error "Для этой задачи нужны права администратора, но на системе
нет ни pkexec (polkit), ни sudo.

Задача НЕ запускалась. Вариант: запустить из консоли root:
  su -c \"bash $SELF\""
            return 1
        fi
        local xauth_probe="" _xa_owner=""
        _xa_owner=$(stat -c '%U' "/tmp/.X11-unix/X${DISPLAY#:}" 2>/dev/null)
        [[ -z "$_xa_owner" || "$_xa_owner" == "root" ]] && \
            _xa_owner="${SUDO_USER:-$(id -un "$orig_uid" 2>/dev/null || true)}"
        for cand in "${XAUTHORITY:-}" \
                    "/run/user/${orig_uid}/xauth" "/run/user/${orig_uid}/.Xauthority" \
                    "/home/${_xa_owner:-astra}/.Xauthority" \
                    "/home/${_xa_owner:-astra}/.Xauthority-$(hostname 2>/dev/null || echo '')" \
                    "/home/${_xa_owner:-astra}/.config/kwinxinput" \
                    "$HOME/.Xauthority" "${XDG_RUNTIME_DIR:-}/xauth"; do
            [[ -n "$cand" && -f "$cand" && -r "$cand" ]] && { xauth_probe="$cand"; break; }
        done
        if [[ -z "$xauth_probe" && -n "${DISPLAY:-}" ]] && have xauth; then
            local _xa_tmp; _xa_tmp="$(mktemp "${TMPDIR:-/tmp}/alt_sync_xauth.XXXXXX")" || _xa_tmp=""
            if [[ -n "$_xa_tmp" ]]; then
                chmod 644 "$_xa_tmp" 2>/dev/null || true
                if xauth -f "${XAUTHORITY:-$HOME/.Xauthority}" nlist "${DISPLAY}" \
                        >"$_xa_tmp" 2>/dev/null && [[ -s "$_xa_tmp" ]]; then
                    xauth_probe="$_xa_tmp"
                    glog "X-authority извлечён через xauth nlist в $_xa_tmp (прямое чтение файла недоступно)"
                else
                    rm -f "$_xa_tmp" 2>/dev/null || true
                fi
            fi
        fi
        [[ -n "$xauth_probe" ]] && export XAUTHORITY="$xauth_probe"
        glog "единственная эскалация прав: $priv_method (диалог пароля — ровно один, до старта работ); XAUTHORITY=${xauth_probe:-—}"
        local -a xargs=()
        [[ -n "${DISPLAY:-}" ]]          && xargs+=(--x-display "$DISPLAY")
        [[ -n "$xauth_probe" ]]          && xargs+=(--x-authority "$xauth_probe")
        [[ -n "${WAYLAND_DISPLAY:-}" ]]  && xargs+=(--wayland-display "$WAYLAND_DISPLAY")
        [[ -n "${XDG_RUNTIME_DIR:-}" || -d "/run/user/$orig_uid" ]] && \
            xargs+=(--xdg-runtime-dir "${XDG_RUNTIME_DIR:-/run/user/$orig_uid}")
        [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && xargs+=(--dbus-address "$DBUS_SESSION_BUS_ADDRESS")
        if (( ${#xargs[@]} > 0 )); then wrapper+=("${xargs[@]}"); fi
        _q() { local s="${1//\'/\'\\\'\'}"; printf "'%s'" "$s"; }
        local -a eexports=()
        [[ -n "${DISPLAY:-}" ]]          && eexports+=("DISPLAY=$(_q "$DISPLAY")")
        [[ -n "$xauth_probe" ]]          && eexports+=("XAUTHORITY=$(_q "$xauth_probe")")
        [[ -n "${WAYLAND_DISPLAY:-}" ]]  && eexports+=("WAYLAND_DISPLAY=$(_q "$WAYLAND_DISPLAY")")
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then eexports+=("XDG_RUNTIME_DIR=$(_q "$XDG_RUNTIME_DIR")")
        elif [[ -d "/run/user/$orig_uid" ]]; then eexports+=("XDG_RUNTIME_DIR='/run/user/$orig_uid'"); fi
        [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && eexports+=("DBUS_SESSION_BUS_ADDRESS=$(_q "$DBUS_SESSION_BUS_ADDRESS")")
        eexports+=("HOME=$(_q "$HOME")" "PATH=$(_q "$PATH")" "LANG=$(_q "${LANG:-C.UTF-8}")" \
                   "TMPDIR=$(_q "${TMPDIR:-/tmp}")" \
                   "ALT_SYNC_ORIG_UID=$(_q "$orig_uid")" \
                   "ALT_SYNC_TASK_ID=$(_q "${ALT_SYNC_TASK_ID:-$$}")" \
                   "ALT_SYNC_WAS_ELEVATED=1" "ALT_SYNC_WRAPPER_PID=$(_q "$$")")
        local inner_cmd="export ${eexports[*]};"
        local warg
        for warg in "${wrapper[@]}"; do inner_cmd+=" $(_q "$warg")"; done
        local -a cmd=()
        case "$priv_method" in
            "sudo (кэш)") cmd=(sudo -n         bash -c "$inner_cmd") ;;
            pkexec)        cmd=(pkexec         bash -c "$inner_cmd") ;;
        esac
        glog "elevated-команда собрана (bash -c, ${#eexports[@]} env-экспортов + $((${#wrapper[@]})) аргументов задачи)"
        "${cmd[@]}"; wrc=$?
        if (( wrc == 126 || wrc == 127 )); then
            gui_dialog error "Повышение прав не удалось (код $wrc). Задача НЕ запускалась.
Запустите вручную из консоли:  su -c \"bash $SELF\""
        fi
        return "$wrc"
    fi

    run_task_launch "$cli" "$label" "$user" "$net" "$moz"
}

progress_health_loop() {
    local label="$1" logf="$2" t0="$3" tstart="$4" _h=0
    while :; do
        kill -0 "${BE_PID:-}" 2>/dev/null || return 0
        if [[ -n "${PP_PID:-}" ]] && ! kill -0 "$PP_PID" 2>/dev/null; then
            glog "FATAL: окно gauge умерло через ${_h}s после старта; stderr: $(head -c 300 "${KD_LAUNCH_LOG:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
            progress_open "$label" "$logf" "$BE_PID" "$t0" "$tstart" || \
                glog "повторный open не удался — прогресс только в терминале/логе"
            return 0
        fi
        sleep 1; _h=$((_h+1))
        (( _h % 60 == 0 )) && printf '[Alt Sync] Задача «%s» работает %d мин, окно прогресса недоступно — следите за логом\n' "$label" $((_h/60)) >&2
    done
}

run_task_launch() {
    local cli="$1" label="$2" user="${3:-}" net="${4:-0}" moz="${5:-0}"

    ALT_SYNC_TASK_ID="${ALT_SYNC_TASK_ID:-$$}"
    export ALT_SYNC_TASK_ID

    local logf
    logf="$GUI_LOG_DIR/alt_sync_live_$(date +%Y%m%d_%H%M%S)_${ALT_SYNC_TASK_ID}.log"
    : >>"$logf" 2>/dev/null || { logf="/tmp/alt_sync_live_$(date +%Y%m%d_%H%M%S)_${ALT_SYNC_TASK_ID}.log"; : >>"$logf" 2>/dev/null || true; }
    chmod a+rw "$logf" 2>/dev/null || true

    local -a be_args=("$cli")
    case "$cli" in
        export|export-offline)
            if [[ "$net" == "1" ]]; then be_args+=(--with-network-keys); else be_args+=(--without-network-keys); fi
            if [[ "$moz" == "1" ]]; then be_args+=(--with-mozilla); else be_args+=(--without-mozilla); fi
            be_args+=(--yes) ;;
        import)                    be_args+=(--defaults) ;;
        import-offline|cryptopro|verify|fetch-deps) be_args+=(--yes) ;;
    esac
    [[ -n "$user" ]] && be_args+=(--user "$user")

    GUI_CANCEL_FLAG="$GUI_LOG_DIR/.cancel.flag.${ALT_SYNC_TASK_ID:-$$}.$cli"
    rm -f "$GUI_CANCEL_FLAG" 2>/dev/null || true
    be_args+=(--log-file "$logf" --cancel-flag "$GUI_CANCEL_FLAG")

    local args_channel=""
    args_channel="$(mktemp "${TMPDIR:-/tmp}/alt_sync_args.XXXXXX")" || args_channel=""
    [[ -n "$args_channel" ]] && { printf '%s\n' "${be_args[@]}" >"$args_channel"; chmod 644 "$args_channel" 2>/dev/null || true; }

    local -a core=()
    core+=("DISPLAY=${DISPLAY:-:0}")
    [[ -n "${XAUTHORITY:-}" && -r "$XAUTHORITY" ]] && core+=("XAUTHORITY=$XAUTHORITY")
    [[ -n "${WAYLAND_DISPLAY:-}" ]] && core+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] && core+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && core+=("DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS")
    core+=("ALT_SYNC_GUI=1" "ALT_SYNC_NONINTERACTIVE=1" "ALT_SYNC_ALLOW_NET=1")
    core+=("ALT_SYNC_NO_AUTOINSTALL=1")
    core+=("ALT_SYNC_ASSUME_YES=1" "DEBIAN_FRONTEND=noninteractive")
    core+=("ALT_SYNC_ELEVATED=1" "ALT_SYNC_NO_ESCALATE=1")
    [[ -n "${ALT_SYNC_GUI:-}" ]] && core+=("ALT_SYNC_GUI=$ALT_SYNC_GUI")
    core+=("ALT_SYNC_SCRIPT_DIR=$SELF_DIR")
    core+=("ALT_SYNC_LOG_FILE=$logf" "ALT_SYNC_CANCEL_FLAG=$GUI_CANCEL_FLAG")
    [[ -n "${ALT_SYNC_ORIG_UID:-}" ]] && core+=("ALT_SYNC_ORIG_UID=$ALT_SYNC_ORIG_UID")
    [[ -n "$user" ]] && core+=("ALT_SYNC_TARGET_USER=$user")
    case "$cli" in
        export|export-offline)
            [[ "$net" == "1" ]] && core+=("ALT_SYNC_BACKUP_NETWORK_KEYS=1")
            [[ "$moz" == "1" ]] && core+=("ALT_SYNC_BACKUP_MOZILLA=1") ;;
    esac
    [[ -n "$args_channel" ]] && core+=("ALT_SYNC_ARGS_FILE=$args_channel")

    GRAPHICS_OK=""
    graphics_probe() {
        [[ -n "$GRAPHICS_OK" ]] && { [[ "$GRAPHICS_OK" == "no" ]] && return 1 || return 0; }
        if have xdpyinfo; then
            DISPLAY="${DISPLAY:-:0}" timeout 5 xdpyinfo >/dev/null 2>&1 && GRAPHICS_OK="x11"
        elif [[ -n "${DISPLAY:-}" && -e "/tmp/.X11-unix/X${DISPLAY#:}" ]]; then
            GRAPHICS_OK="x11-socket"
        fi
        if [[ -z "$GRAPHICS_OK" && -n "${WAYLAND_DISPLAY:-}" ]] \
            && [[ -e "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY}" ]]; then
            GRAPHICS_OK="wayland"
        fi
        if [[ -z "$GRAPHICS_OK" && -n "${WIDGET_BIN:-}" ]]; then
            local _prc=0
            timeout 5 "$WIDGET_BIN" --help >/dev/null 2>&1 || _prc=$?
            if (( _prc != 3 )); then GRAPHICS_OK="widget-ok"; fi
        fi
        [[ -z "$GRAPHICS_OK" ]] && GRAPHICS_OK="no"
        glog "доступность графики из этого процесса: $GRAPHICS_OK (DISPLAY=${DISPLAY:-—}, WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-—})"
        [[ "$GRAPHICS_OK" == "no" ]] && return 1 || return 0
    }

    local -a runner=(env "${core[@]}" bash "$BACKEND_SCRIPT")

    if [[ ! -f "$BACKEND_SCRIPT" ]]; then
        glog "FATAL: бэкенд не найден из elevated-обёртки: $BACKEND_SCRIPT (HOME=$HOME, EUID=$EUID)"
        gui_dialog error "После подтверждения прав бэкенд alt_sync.sh не найден по пути:
$BACKEND_SCRIPT
Проверьте, что оба файла комплекта лежат в одной папке и она доступна
(носитель не отмонтирован). Задача НЕ запускалась."
        dialog_lock_release 2>/dev/null || true
        return 1
    fi

    glog "задача cli=$cli аргументы=${be_args[*]} пользователь=${user:-}"
    printf 'INIT: GUI v%s запускает задачу "%s" (лог %s)\n' "$GUI_VERSION" "$cli" "$logf" >"$logf" 2>/dev/null || true

    if ! graphics_probe; then
        glog "WARNING: нет доступа к дисплею из этого процесса; окно прогресса откроется в режиме --menu, следите также за логом: $logf"
        printf '[Alt Sync] ВНИМАНИЕ: нет доступа к дисплею из root-процесса — окно прогресса будет упрощённым (--menu).\n' >&2
    fi

    "${runner[@]}" "${be_args[@]}" </dev/null >/dev/null 2>&1 &
    BE_PID=$!

    _imm=0
    while (( _imm < 3 )); do
        kill -0 "$BE_PID" 2>/dev/null || break
        sleep 1; _imm=$((_imm+1))
    done
    if ! kill -0 "$BE_PID" 2>/dev/null; then
        wait "$BE_PID" 2>/dev/null; rc=$?
        glog "FATAL: бэкенд умер сразу после старта (rc=$rc); бэклог: $(tail -5 "$logf" 2>/dev/null | tr '\n' ' ')"
        gui_dialog error "Задача «$label» не смог стартовать (код $rc).
Бэкенд: $BACKEND_SCRIPT
Лог: $logf
Частые причины: файл alt_sync.sh перемещён/отмонтирован после запуска GUI,
или нарушены права на каталог логов. Запустите комплект заново."
        BE_PID=""
        return "$rc"
    fi
    if [[ -n "$args_channel" ]]; then
        ( wait "$BE_PID" 2>/dev/null; rm -f "$args_channel" ) &
        disown $! 2>/dev/null || true
    fi

    local t0 rc=0 cancelled=0 w=0
    t0=$(date +%s)
    local tstart; tstart=$(date '+%H:%M')

    dialog_lock_acquire || true

    progress_open "$label" "$logf" "$BE_PID" "$t0" "$tstart" || true
    if [[ -n "${PP_PID:-}" ]]; then
        progress_health_loop "$label" "$logf" "$t0" "$tstart" &
        PP_HEALTH=$!
        disown "$PP_HEALTH" 2>/dev/null || true
    fi
    local _bootw=0 _bootok=""
    while (( _bootw < 10 )); do
        if grep -qa 'PROGRESS|' "$logf" 2>/dev/null; then _bootok=1; break; fi
        kill -0 "$BE_PID" 2>/dev/null || { _bootok=1; break; }
        sleep 1; _bootw=$((_bootw+1))
    done
    if [[ -z "$_bootok" ]] && ! grep -qa 'PROGRESS|' "$logf" 2>/dev/null; then
        glog "нет PROGRESS-меток через ${_bootw}s — бэкенд в фазе подготовки окружения"
        printf '[%s] INFO: Подготовка окружения: сбор списков пакетов и инициализация (первый запуск может занять несколько минут)…\n' \
            "$(date '+%F %T')" >>"$logf" 2>/dev/null || true
    fi

    while :; do
        if cancel_requested; then cancelled=1; break; fi
        kill -0 "$BE_PID" 2>/dev/null || break
        sleep 1
    done
    if (( cancelled )); then
        kill "$BE_PID" 2>/dev/null || true
        while kill -0 "$BE_PID" 2>/dev/null && (( w < 10 )); do sleep 1; w=$((w+1)); done
        kill -9 "$BE_PID" 2>/dev/null || true
        wait "$BE_PID" 2>/dev/null; rc=130
    else
        wait "$BE_PID" 2>/dev/null; rc=$?
        if (( rc == 130 )) && ! cancel_requested; then
            glog "rc=130 без явной отмены — считаю задачу завершённой"
            rc=0
        fi
    fi
    BE_PID=""
    progress_close

    local last; last=$(tail -1 "$logf" 2>/dev/null | tr -d '\r')
    if [[ "${PP_FINAL_SHOWN:-}" == "1" ]]; then
        PP_FINAL_SHOWN=""
        glog "итог показан окном прогресса (kdmenu), повторное окно пропущено"
        dialog_lock_release
        return "$rc"
    fi
    if (( rc == 0 )); then
        if [[ "$cli" == "fetch-deps" ]]; then
            gui_dialog info "📦 Офлайн-кэш компонентов готов: $SELF_DIR/deps-rpm
Перенесите всю папку скрипта на компьютеры без интернета — недостающие
пакеты установятся оттуда автоматически."
        else
            gui_dialog info "✅ Готово: $label.${last:+
$last}
Лог: $logf"
        fi
    elif (( rc == 130 )); then
        gui_dialog warning "⛔ Задача «$label» отменена пользователем.
Частично созданные файлы могут остаться в папке слепка.
Лог: $logf"
    else
        GUI_DIALOG_TITLE="$APP_TITLE — Лог ошибки ($cli)" gui_dialog viewfile "$logf"
    fi
    dialog_lock_release
    return "$rc"
}

show_menu() {
    local choice="" idx items=()
    if [[ "${WIDGET_BIN:-}" == kdialog || "${WIDGET_BIN##*/}" == kdialog ]]; then
        kd_detect_features
        GUI_LIST_ITEMS=()
        local i
        for ((i=0; i<${#ACTIONS[@]}; i++)); do
            GUI_LIST_ITEMS+=( "$((i+1))" "${ACTIONS[$i]}" )
        done
        choice=$(GUI_DIALOG_TITLE="$APP_TITLE" gui_dialog list \
            "Alt Sync v$GUI_VERSION — выберите действие:") || return 1
        choice="${choice//[[:space:]]/}"
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ACTIONS[@]} )) || return 1
        printf '%s\n' "${ACTIONS[$((choice-1))]}"
        return 0
    fi
    GUI_LIST_ITEMS=("${ACTIONS[@]}")
    choice=$(GUI_DIALOG_TITLE="$APP_TITLE" gui_dialog list \
        "<b>Alt Sync v$GUI_VERSION</b> — выберите действие:") || return 1
    choice="${choice#│ }"; choice="${choice%│*}"; choice="${choice//│/}"
    [[ -n "$choice" ]] || return 1
    printf '%s\n' "$choice"
}

run_action() {
    local choice="$1"
    glog "выбрано действие: $choice"

    local mapped cli confirm label
    mapped=$(map_action "$choice")
    if [[ -z "$mapped" ]]; then
        gui_dialog warning "Неизвестное действие: $choice"
        return 1
    fi
    IFS='|' read -r cli confirm label <<<"$mapped"

    case "$cli" in
        report)    view_report; return 0 ;;
        backupdir) view_backup_dir; return 0 ;;
    esac

    local net=0 moz=0 user="" ans="" erc uerr rcf
    rcf="$(mktemp "${TMPDIR:-/tmp}/alt_sync_ans.XXXXXX")" || { gui_die "mktemp failed" 5; }

    case "$cli" in
        export|export-offline)
            export_opts_window "$(detect_default_user)" >"$rcf"; erc=$?
            ans="$(cat "$rcf" 2>/dev/null)"
            rm -f "$rcf"
            if (( erc != 0 )) || [[ -z "$ans" ]]; then
                glog "экспорт отменён на шаге опций/имени (rc=$erc) — выход без запуска"
                return 0
            fi
            IFS='|' read -r user net moz <<<"$ans"
            ;;
        import|import-offline|cryptopro)
            GUI_DIALOG_TITLE="$APP_TITLE — Владелец профиля"
            gui_entry_ok_cancel "Профиль какого пользователя использовать?" \
                "$(detect_default_user)" >"$rcf"; uerr=$?
            user="$(cat "$rcf" 2>/dev/null)"
            rm -f "$rcf"
            user="${user//[[:space:]]/}"
            if (( uerr != 0 )) || [[ -z "$user" ]]; then
                glog "действие отменено на шаге имени пользователя"
                return 0
            fi
            ;;
        *)
            rm -f "$rcf"
            user="$(detect_default_user)"
            ;;
    esac

    [[ "$confirm" == "confirm" ]] && {
        gui_confirm_dangerous "⚠ ВНИМАНИЕ! Импорт изменит пакеты, /etc, /opt и
пользовательский профиль на ЭТОЙ машине (она станет клоном эталона)." || \
            { glog "запуск отменён пользователем на подтверждении"; return 0; }
    }

    run_backend "$cli" "$label" "$user" "$net" "$moz"
    return 0
}

main() {
    if [[ "${1:-}" == "--run-task" ]]; then
        shift
        local rt_cli="${1:-}" rt_label="${2:-Задача}"; shift 2 2>/dev/null || true
        local rt_user="${1:-}" rt_net="${2:-0}" rt_moz="${3:-0}"; shift 3 2>/dev/null || true
        case "$rt_cli" in
            export|export-offline|import|import-offline|cryptopro|verify|fetch-deps) : ;;
            *) gui_die "некорректный вызов --run-task: '$rt_cli'" 64 ;;
        esac
        local rt_arg rt_val
        while (( $# > 0 )); do
            rt_arg="$1"; shift
            case "$rt_arg" in
                --elevated-marker)
                    export ALT_SYNC_WAS_ELEVATED=1 ;;
                --gui-self=*)
                    export ALT_SYNC_GUI_SELF="${rt_arg#*=}" ;;
                --backend=*)
                    export ALT_SYNC_BACKEND_ARG="${rt_arg#*=}" ;;
                --task-id=*)
                    export ALT_SYNC_TASK_ID="${rt_arg#*=}" ;;
                --x-display)
                    rt_val="${1:-}"; shift || true
                    [[ -n "$rt_val" && -z "${DISPLAY:-}" ]] && export DISPLAY="$rt_val" ;;
                --x-authority)
                    rt_val="${1:-}"; shift || true
                    if [[ -n "$rt_val" && -f "$rt_val" ]] \
                        && { [[ -z "${XAUTHORITY:-}" ]] || [[ ! -r "${XAUTHORITY:-/nonexistent}" ]]; }; then
                        export XAUTHORITY="$rt_val"
                    fi ;;
                --wayland-display)
                    rt_val="${1:-}"; shift || true
                    [[ -n "$rt_val" && -z "${WAYLAND_DISPLAY:-}" ]] && export WAYLAND_DISPLAY="$rt_val" ;;
                --xdg-runtime-dir)
                    rt_val="${1:-}"; shift || true
                    if [[ -n "$rt_val" && -d "$rt_val" ]] && [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
                        export XDG_RUNTIME_DIR="$rt_val"
                    fi ;;
                --dbus-address)
                    rt_val="${1:-}"; shift || true
                    [[ -n "$rt_val" && -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && \
                        export DBUS_SESSION_BUS_ADDRESS="$rt_val" ;;
                *) : ;;
            esac
        done
        [[ -n "${ALT_SYNC_GUI_SELF:-}" && -f "${ALT_SYNC_GUI_SELF:-}" ]] && SELF="$ALT_SYNC_GUI_SELF"
        if [[ -n "${ALT_SYNC_BACKEND_ARG:-}" && -f "${ALT_SYNC_BACKEND_ARG:-}" ]]; then
            BACKEND_SCRIPT="$ALT_SYNC_BACKEND_ARG"
        fi
        glog "elevated-обёртка: EUID=$EUID, TASK_ID=${ALT_SYNC_TASK_ID:-—}, backend=$BACKEND_SCRIPT, DISPLAY=${DISPLAY:-—}, XAUTHORITY=${XAUTHORITY:-—}"
        run_backend "$rt_cli" "$rt_label" "$rt_user" "$rt_net" "$rt_moz"
        return $?
    fi

    if (( $# > 0 )); then
        local first="$1"; shift
        local mapped cli confirm label
        mapped=$(map_action "$first")
        if [[ -n "$mapped" ]]; then
            IFS='|' read -r cli confirm label <<<"$mapped"
            run_backend "$cli" "$label" "$(detect_default_user)" \
                "${ALT_SYNC_BACKUP_NETWORK_KEYS:-0}" "${ALT_SYNC_BACKUP_MOZILLA:-0}"
            return $?
        fi
        exec bash "$BACKEND_SCRIPT" "$first" "$@"
    fi

    if [[ ! -f "$BACKEND_SCRIPT" ]]; then
        for cand in "$HOME/alt_sync.sh" "$HOME/Загрузки/alt_sync.sh" "/usr/local/share/alt_sync/alt_sync.sh"; do
            [[ -f "$cand" ]] && BACKEND_SCRIPT="$cand" && break
        done
    fi
    glog "backend=$BACKEND_SCRIPT существует=$([[ -f "$BACKEND_SCRIPT" ]] && echo да || echo НЕТ)"
    glog "среда=$ENV_NAME, display=${DISPLAY:-${WAYLAND_DISPLAY:-—}}, виджет=${WIDGET_BIN:-нет}, card=$CARD_STYLE"

    if [[ ! -f "$BACKEND_SCRIPT" ]]; then
        gui_die "не найден alt_sync.sh рядом с $SELF.
Положите оба файла комплекта в одну папку или задайте ALT_SYNC_BACKEND." 4
    fi

    if [[ -z "$WIDGET_BIN" ]]; then
        printf 'Alt Sync GUI: диалоговые виджеты (yad/zenity/kdialog/qarma) не найдены.\n' >&2
        printf 'Открываю текстовый интерфейс бэкенда...\n' >&2
        exec bash "$BACKEND_SCRIPT" "$@"
    fi

    local choice="" chfile
    chfile="$(mktemp "${TMPDIR:-/tmp}/alt_sync_choice.XXXXXX")" || { gui_die "mktemp failed" 5; }
    if [[ "${WIDGET_BIN:-}" == kdialog || "${WIDGET_BIN##*/}" == kdialog ]]; then
        show_menu >"$chfile"
    else
        GUI_DIALOG_TITLE="$APP_TITLE" show_menu >"$chfile"
    fi
    local mrc=$?
    choice=$(cat "$chfile" 2>/dev/null)
    rm -f "$chfile" 2>/dev/null || true
    if (( mrc != 0 )) || [[ -z "$choice" ]]; then
        glog "меню закрыто без выбора (rc=$mrc) — выход"
        return 0
    fi
    run_action "$choice"
}

main "$@"