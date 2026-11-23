#!/usr/bin/env bash
# orgBox Server Manager — dependency-light Bash server dashboard.
# Runs as the current user. Does not manage Docker/Nginx or require sudo.
set -u

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONF="$DIR/manager.conf"
DATA="$DIR/manager.csv"
LOCK="$DIR/.manager.lock"
MARKER_START='# >>> orgbox_server_manager >>>'
MARKER_END='# <<< orgbox_server_manager <<<' 
DEFAULT_PERIOD=72
REFRESH_SECONDS=3
HISTORY_DAYS=30
SAMPLE_SECONDS=60
GRAPH_HEIGHT=10
SERVER_NAME="$(hostname 2>/dev/null || printf 'server')"
MENU_KEYS=() MENU_LABELS=() MENU_CMDS=()

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

load_config() {
  MENU_KEYS=() MENU_LABELS=() MENU_CMDS=()
  [[ -f "$CONF" ]] || return 0
  local line key val label cmd reserved
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(SERVER_NAME|DEFAULT_PERIOD|REFRESH_SECONDS|HISTORY_DAYS|SAMPLE_SECONDS|GRAPH_HEIGHT)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"; val="$(trim "${BASH_REMATCH[2]}")"
      [[ "$val" == \"*\" ]] && val="${val:1:${#val}-2}"
      case "$key" in
        SERVER_NAME) SERVER_NAME="$val" ;;
        DEFAULT_PERIOD) [[ "$val" =~ ^(24|72|168)$ ]] && DEFAULT_PERIOD="$val" ;;
        REFRESH_SECONDS) [[ "$val" =~ ^[0-9]{1,2}$ ]] && ((10#$val>=1 && 10#$val<=60)) && REFRESH_SECONDS="$((10#$val))" ;;
        HISTORY_DAYS) [[ "$val" =~ ^[0-9]{1,3}$ ]] && ((10#$val>=1 && 10#$val<=365)) && HISTORY_DAYS="$((10#$val))" ;;
        SAMPLE_SECONDS) [[ "$val" =~ ^(60|120|300|600)$ ]] && SAMPLE_SECONDS="$val" ;;
        GRAPH_HEIGHT) [[ "$val" =~ ^[0-9]{1,2}$ ]] && ((10#$val>=4 && 10#$val<=15)) && GRAPH_HEIGHT="$((10#$val))" ;;
      esac
    elif [[ "$line" == *'|'* ]]; then
      IFS='|' read -r key label cmd <<< "$line"
      key="$(trim "$key")"; label="$(trim "$label")"; cmd="$(trim "$cmd")"
      reserved='123reqx'
      if [[ "$key" =~ ^[a-zA-Z0-9]$ && "$reserved" != *"${key,,}"* && -n "$label" && -n "$cmd" ]]; then
        MENU_KEYS+=("$key"); MENU_LABELS+=("$label"); MENU_CMDS+=("$cmd")
      fi
    fi
  done < "$CONF"
}
load_config

cpu_ticks() { awk '/^cpu / { idle=$5+$6; total=0; for(i=2;i<=NF;i++)total+=$i; print total,idle; exit }' /proc/stat 2>/dev/null; }
cpu_usage() {
  local first second a b x y
  first="$(cpu_ticks)"; sleep 0.25; second="$(cpu_ticks)"
  read -r a b <<< "$first"; read -r x y <<< "$second"
  awk -v dt="$((${x:-0}-${a:-0}))" -v di="$((${y:-0}-${b:-0}))" 'BEGIN { if(dt>0)printf "%.1f",100*(dt-di)/dt; else printf "0.0" }'
}
ram_usage() { awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if(t>0)printf "%.1f",100*(t-a)/t;else printf "0.0"}' /proc/meminfo 2>/dev/null; }
disk_usage() { df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0; ok=1} END{if(!ok)print "0"}'; }

release_lock() {
  rm -f -- "$LOCK/pid" 2>/dev/null || :
  rmdir -- "$LOCK" 2>/dev/null || :
}
collect() {
  [[ -r /proc/stat && -r /proc/meminfo ]] || { echo 'ERROR: CPU/RAM statistics unavailable in /proc' >&2; return 1; }
  local pid='' now cpu ram disk tmp cutoff marker last=0
  if ! mkdir -- "$LOCK" 2>/dev/null; then
    if [[ -r "$LOCK/pid" ]]; then read -r pid < "$LOCK/pid"; fi
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then return 0; fi
    if [[ ! -f "$LOCK/pid" || "$pid" =~ ^[0-9]+$ ]]; then
      rm -f -- "$LOCK/pid" 2>/dev/null || :
      rmdir -- "$LOCK" 2>/dev/null || return 0
      mkdir -- "$LOCK" 2>/dev/null || return 0
    else
      return 0
    fi
  fi
  printf '%s\n' "$$" > "$LOCK/pid"
  trap release_lock EXIT HUP INT TERM
  now="$(date +%s)"; cpu="$(cpu_usage)"; ram="$(ram_usage)"; disk="$(disk_usage)"
  if [[ ! -s "$DATA" ]]; then printf 'timestamp,cpu,ram,disk\n' > "$DATA"; fi
  printf '%s,%s,%s,%s\n' "$now" "$cpu" "$ram" "$disk" >> "$DATA" || return 1

  # Daily CSV rotation, retaining HISTORY_DAYS days. Atomic replace; no archives.
  marker="$DIR/.manager-rotation"
  if [[ -r "$marker" ]]; then read -r last < "$marker"; fi
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if ((now-last>=86400)); then
    cutoff=$((now-HISTORY_DAYS*86400))
    tmp="$(mktemp "$DIR/.manager-XXXXXX")" || return 1
    if awk -F, -v cutoff="$cutoff" 'NR==1 || ($1 ~ /^[0-9]+$/ && $1>=cutoff)' "$DATA" > "$tmp"; then
      chmod 600 "$tmp"; mv -f -- "$tmp" "$DATA"
      printf '%s\n' "$now" > "$marker"
    else
      rm -f -- "$tmp"; return 1
    fi
  fi
  release_lock; trap - EXIT HUP INT TERM
}

bar() {
  local value="$1" width="$2" filled i result=''
  filled="$(awk -v v="$value" -v w="$width" 'BEGIN {n=int(v*w/100+0.5); if(n<0)n=0;if(n>w)n=w;print n}')"
  for ((i=0;i<width;i++)); do if ((i<filled)); then result+='█'; else result+='░'; fi; done
  printf '%s' "$result"
}

graph() {
  local field="$1" hours="$2" width="$3" title="$4" now="$5" cutoff
  cutoff=$((now-hours*3600))
  printf '\n%s · последние %s ч\n' "$title" "$hours"
  if [[ ! -s "$DATA" ]]; then printf '  История ещё не накоплена\n'; return; fi
  awk -F, -v field="$field" -v cutoff="$cutoff" -v now="$now" -v width="$width" -v height="$GRAPH_HEIGHT" '
    NR>1 && $1 ~ /^[0-9]+$/ && $1>=cutoff && $1<=now {
      ix=int(($1-cutoff)*width/(now-cutoff+1));if(ix>=width)ix=width-1
      val=$field+0;if(val<0)val=0;if(val>100)val=100
      if(!(ix in peak)||val>peak[ix])peak[ix]=val
      sum+=val;cnt++;if(cnt==1||val<min)min=val;if(cnt==1||val>max)max=val
    }
    END {
      if(!cnt){print "  Нет замеров за выбранный период";exit}
      for (step=height;step>=1;step--) {
        threshold=100*step/height
        printf "%3.0f%%│",threshold
        for(i=0;i<width;i++)printf ((i in peak)&&peak[i]>=threshold)?"█":" "
        printf "\n"
      }
      printf "  0%%└";for(i=0;i<width;i++)printf "─";printf "\n"
      printf "  Среднее %.1f%%  Мин %.1f%%  Макс %.1f%%  Замеров %d\n",sum/cnt,min,max,cnt
    }' "$DATA"
  printf '  %s  →  %s\n' "$(date -d "@$cutoff" '+%d.%m %H:%M')" "$(date -d "@$now" '+%d.%m %H:%M')"
}

render() {
  local hours="$1" now cpu ram disk cols width live_width
  now="$(date +%s)"; cpu="$(cpu_usage)"; ram="$(ram_usage)"; disk="$(disk_usage)"
  cols="$(tput cols 2>/dev/null || printf 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  width=$((cols-8)); ((width>72)) && width=72; ((width<12)) && width=12
  live_width=$((cols-19)); ((live_width>28)) && live_width=28; ((live_width<8)) && live_width=8
  printf '\033[H\033[2J'
  printf 'orgBox Server Manager  |  %s  |  %s  |  %s\n' "$SERVER_NAME" "$(id -un)" "$(date '+%d.%m.%Y %H:%M:%S')"
  printf 'LIVE · обновление каждые %s сек\n' "$REFRESH_SECONDS"
  printf 'CPU    [%s] %5s%%\n' "$(bar "$cpu" "$live_width")" "$cpu"
  printf 'RAM    [%s] %5s%%\n' "$(bar "$ram" "$live_width")" "$ram"
  printf 'DISK / [%s] %5s%%\n' "$(bar "$disk" "$live_width")" "$disk"
  graph 2 "$hours" "$width" CPU "$now"
  graph 3 "$hours" "$width" RAM "$now"
  graph 4 "$hours" "$width" 'DISK /' "$now"
  printf '\n[1] 24ч  [2] 3 дня  [3] 7 дней  [r] Обновить  [e] Редактировать меню\n'
  local i
  for ((i=0;i<${#MENU_KEYS[@]};i++)); do printf '[%s] %s  ' "${MENU_KEYS[i]}" "${MENU_LABELS[i]}"; done
  printf '\n[q] Bash  [x] Выйти из SSH\n'
}

# Проверка обновлений выполняется только при запуске интерактивного меню.
# collect/install/uninstall не обращаются к сети.
check_updates() {
  [[ -t 0 && -t 1 ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local current latest response choice installer tmp
  current="0.1.0"
  [[ -r "$DIR/VERSION" ]] && read -r current < "$DIR/VERSION"
  response="$(curl -fsSL --connect-timeout 3 --max-time 6     -H 'Accept: application/vnd.github+json'     'https://api.github.com/repos/EugeneSlusar/orgBox_Server_Manager/releases/latest' 2>/dev/null)" || return 0
  latest="$(printf '%s\n' "$response" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+"' | head -n 1 | sed -E 's/.*"v?([0-9]+\.[0-9]+\.[0-9]+)"/\1/')" 
  [[ -n "$latest" && "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  if [[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)" == "$latest" && "$latest" != "$current" ]]; then
    printf '\nДоступна новая версия orgBox Server Manager: v%s (установлена v%s)\n' "$latest" "$current"
    printf 'Обновить сейчас? [y/N]: '
    IFS= read -r choice || return 0
    [[ "$choice" == y || "$choice" == Y || "$choice" == д || "$choice" == Д ]] || return 0
    tmp="$(mktemp)" || return 0
    installer="https://raw.githubusercontent.com/EugeneSlusar/orgBox_Server_Manager/v$latest/install.sh"
    if curl -fsSL --connect-timeout 5 --max-time 30 "$installer" -o "$tmp"; then
      if bash -n "$tmp" && ORGBOX_VERSION="v$latest" bash "$tmp"; then
        rm -f "$tmp"
        exec bash "$DIR/manager.sh" monitor
      fi
    fi
    rm -f "$tmp"
    printf 'Обновление не удалось. Продолжаем текущую версию.\n'
    sleep 2
  fi
}

run_menu() {
  check_updates
  local hours="${1:-$DEFAULT_PERIOD}" key i command_text
  [[ "$hours" =~ ^(24|72|168)$ ]] || hours=72
  [[ -t 0 && -t 1 ]] || { echo 'Для просмотра нужен интерактивный терминал' >&2; return 1; }
  trap 'printf "\033[?25h"' RETURN
  while :; do
    render "$hours"
    key=''; IFS= read -rsn1 -t "$REFRESH_SECONDS" key || :
    case "$key" in
      1) hours=24;; 2) hours=72;; 3) hours=168;; r|R|'') ;;
      q|Q) printf '\033[H\033[2J'; break ;;
      x|X) exit 0 ;;
      e|E)
        if command -v "${EDITOR:-nano}" >/dev/null 2>&1; then "${EDITOR:-nano}" "$CONF"; else "${EDITOR:-vi}" "$CONF"; fi
        load_config ;;
      *)
        for ((i=0;i<${#MENU_KEYS[@]};i++)); do
          if [[ "$key" == "${MENU_KEYS[i]}" ]]; then
            command_text="${MENU_CMDS[i]}"
            printf '\033[H\033[2J\n%s\n\n' "Команда: $command_text"
            # Commands are deliberately from trusted, user-editable manager.conf.
            bash -c "$command_text"
            read -rp $'\nEnter для возврата...' _ || :
            break
          fi
        done ;;
    esac
  done
}

install() {
  local profile="$HOME/.bashrc" cron_line temp unit_dir
  [[ "$DIR" == "$HOME/orgbox_server_manager" ]] || { echo "Папка должна находиться в $HOME/orgbox_server_manager" >&2; return 1; }
  [[ -f "$CONF" ]] || { echo 'Нет manager.conf' >&2; return 1; }
  chmod u+x "$DIR/manager.sh" || return 1
  umask 077
  touch -- "$profile" || return 1
  if ! grep -Fqx "$MARKER_START" "$profile"; then
    cat >> "$profile" <<PROFILE

$MARKER_START
# Only interactive SSH sessions. No startup for scp, cron, or nested shells.
if [[ \$- == *i* && -n "\${SSH_TTY:-}" && -z "\${ORGBOX_MANAGER_ACTIVE:-}" ]]; then
  export ORGBOX_MANAGER_ACTIVE=1
  "$DIR/manager.sh" monitor
  unset ORGBOX_MANAGER_ACTIVE
fi
$MARKER_END
PROFILE
  fi
  if command -v crontab >/dev/null 2>&1; then
    # Per-user cron: no root/sudo and continues between SSH sessions.
    local schedule='* * * * *'
    case "$SAMPLE_SECONDS" in 120) schedule='*/2 * * * *';; 300) schedule='*/5 * * * *';; 600) schedule='*/10 * * * *';; esac
    cron_line="$schedule /bin/bash '$DIR/manager.sh' collect >/dev/null 2>&1 # orgbox_server_manager"
    temp="$(mktemp)" || return 1
    (crontab -l 2>/dev/null || :) | grep -v '# orgbox_server_manager$' > "$temp" || :
    printf '%s\n' "$cron_line" >> "$temp"
    if crontab "$temp"; then echo 'Cron: периодический сбор включён'; else echo 'ВНИМАНИЕ: не удалось зарегистрировать cron'; fi
    rm -f "$temp"
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    unit_dir="$HOME/.config/systemd/user"; mkdir -p "$unit_dir"
    cat > "$unit_dir/orgbox-manager.service" <<UNIT
[Unit]
Description=Collect orgBox server usage
[Service]
Type=oneshot
ExecStart=/bin/bash $DIR/manager.sh collect
UNIT
    cat > "$unit_dir/orgbox-manager.timer" <<UNIT
[Unit]
Description=Collect orgBox usage every $SAMPLE_SECONDS seconds
[Timer]
OnCalendar=*-*-* *:*:00
Persistent=true
Unit=orgbox-manager.service
[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    if systemctl --user enable --now orgbox-manager.timer; then echo 'User systemd timer: включён'; else echo 'ВНИМАНИЕ: ошибка при запуске таймера'; fi
    if command -v loginctl >/dev/null 2>&1 && ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      echo "ВНИМАНИЕ: user systemd может остановиться после выхода из SSH. Root может включить: loginctl enable-linger $(id -un)"
    fi
  else
    echo "ВНИМАНИЕ: cron/systemd недоступны. Для истории настрой планировщик: bash '$DIR/manager.sh' collect"
  fi
  collect || echo 'ВНИМАНИЕ: первый замер не записался (проверь доступ к /proc)'
  echo "Готово. Следующий SSH-вход: дашборд. Папка: $DIR"
}

uninstall() {
  local profile="$HOME/.bashrc" tmp
  if [[ -f "$profile" ]]; then
    tmp="$(mktemp)" || return 1
    awk -v a="$MARKER_START" -v b="$MARKER_END" '$0==a{skip=1;next}$0==b{skip=0;next}!skip{print}' "$profile" > "$tmp" && cat "$tmp" > "$profile"
    rm -f "$tmp"
  fi
  if command -v crontab >/dev/null 2>&1; then
    tmp="$(mktemp)" || return 1
    (crontab -l 2>/dev/null || :) | grep -v '# orgbox_server_manager$' > "$tmp" || :
    crontab "$tmp"; rm -f "$tmp"
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now orgbox-manager.timer 2>/dev/null || :
    rm -f -- "$HOME/.config/systemd/user/orgbox-manager.timer" "$HOME/.config/systemd/user/orgbox-manager.service"
    systemctl --user daemon-reload
  fi
  echo 'Автозапуск и сбор отключены. Конфигурация и история оставлены.'
}

case "${1:-monitor}" in
  install) install;; uninstall) uninstall;; collect) collect;; monitor) run_menu "${2:-$DEFAULT_PERIOD}";;
  *) printf 'Использование: manager.sh [install|uninstall|collect|monitor [24|72|168]]\n'; exit 2;;
esac