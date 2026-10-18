# Schedule times, one parser for every schedule: the brief and any job (jobs/<job>.job WHEN),
# the backup time, and the digest. Sourced by lib.sh and by the cabinet command, never run.
#
# A WHEN is a time, every day ("7:00 AM", "daily 7 AM"), or days and a time ("fri 4 PM",
# "sun,mon,tue,wed,thu 8:30 AM"). Times are 12-hour with AM or PM ("10 AM", "4:30 pm");
# without AM or PM they are read as 24-hour ("16:00"), so files written that way still work.
# Days by three letters or full name, any case: "Friday 4 PM". It is stored and shown 12-hour.

# when_parse <when>: sets WHEN_DAYS (comma list in week order, empty for every day),
# WHEN_H (0-23) and WHEN_M; returns 1 when it is not a schedule time.
when_parse() {
  local w days h m ap d out="" n=0
  WHEN_DAYS="" WHEN_H="" WHEN_M=""
  w="$(printf %s "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '  ' | sed 's/a\.m\./am/; s/p\.m\./pm/')"; w="${w# }"; w="${w% }"
  w="${w#daily }"
  [[ "$w" =~ ^(([a-z]+([[:space:]]*,[[:space:]]*[a-z]+)*)[[:space:]]+)?([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)?$ ]] || return 1
  days="${BASH_REMATCH[2]// /}" h="${BASH_REMATCH[4]}" m="${BASH_REMATCH[6]}" ap="${BASH_REMATCH[7]}"
  h=$((10#$h)); m=$((10#${m:-0}))
  if [[ -n "$ap" ]]; then
    ((h >= 1 && h <= 12)) || return 1
    ((h == 12)) && h=0; [[ "$ap" == pm ]] && h=$((h + 12))
  else
    [[ -n "${BASH_REMATCH[6]}" ]] || return 1   # "10" alone: AM or PM?
    ((h <= 23)) || return 1
  fi
  ((m <= 59)) || return 1
  if [[ -n "$days" ]]; then
    for d in ${days//,/ }; do
      [[ " sun mon tue wed thu fri sat sunday monday tuesday wednesday thursday friday saturday " == *" $d "* ]] || return 1
    done
    for d in sun mon tue wed thu fri sat; do
      case ",$days," in *",$d,"*|*",$(when_day_name "$d"),"*) out+="${out:+,}$d"; n=$((n + 1)) ;; esac
    done
    ((n == 7)) && out=""   # all seven days: every day
  fi
  WHEN_DAYS="$out" WHEN_H="$h" WHEN_M="$m"
}
when_day_name() { case "$1" in sun) echo sunday ;; mon) echo monday ;; tue) echo tuesday ;; wed) echo wednesday ;; thu) echo thursday ;; fri) echo friday ;; sat) echo saturday ;; esac; }
when_clock() { local h=$1 m=$2 ap=AM; ((h >= 12)) && ap=PM; h=$((h % 12)); ((h == 0)) && h=12; printf '%s:%02d %s' "$h" "$m" "$ap"; }

# when_norm <when>: the stored form, "7:00 AM" or "fri,sat 4:00 PM"; return 1 when it is not one.
when_norm() {
  when_parse "$1" || return 1
  printf '%s%s' "${WHEN_DAYS:+$WHEN_DAYS }" "$(when_clock "$WHEN_H" "$WHEN_M")"
}

# when_time_only <time>: when_norm for a time that names no day (the backup time).
when_time_only() {
  local l; l="$(printf %s "$1" | tr '[:upper:]' '[:lower:]')"; l="${l#daily }"
  [[ "$l" != *[a-z][a-z][a-z]* ]] && when_norm "$1"   # day names are three letters or more; am and pm are two
}

# when_calendar <when>: launchd StartCalendarInterval entries, one <dict> per day, for an <array>.
when_calendar() {
  local d i=0
  when_parse "$1" || return 1
  if [[ -z "$WHEN_DAYS" ]]; then printf '<dict><key>Hour</key><integer>%s</integer><key>Minute</key><integer>%s</integer></dict>' "$WHEN_H" "$WHEN_M"; return 0; fi
  for d in sun mon tue wed thu fri sat; do
    [[ ",$WHEN_DAYS," == *",$d,"* ]] && printf '<dict><key>Weekday</key><integer>%s</integer><key>Hour</key><integer>%s</integer><key>Minute</key><integer>%s</integer></dict>' "$i" "$WHEN_H" "$WHEN_M"
    i=$((i + 1))
  done
  return 0
}

# when_human <when>: for people, "every day at 7:00 AM" or "Fri, Sat at 4:00 PM".
when_human() {
  local d out=""
  when_parse "$1" || { printf '%s' "$1"; return 0; }
  if [[ -z "$WHEN_DAYS" ]]; then printf 'every day at %s' "$(when_clock "$WHEN_H" "$WHEN_M")"; return 0; fi
  for d in ${WHEN_DAYS//,/ }; do out+="${out:+, }$(printf %s "${d:0:1}" | tr '[:lower:]' '[:upper:]')${d:1}"; done
  printf '%s at %s' "$out" "$(when_clock "$WHEN_H" "$WHEN_M")"
}
