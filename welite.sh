#!/bin/bash
# welite.sh — WeChat Web API shell client
S=./welite.sock J=./welite_cookies.txt C=./welite_contacts.json F=${2:-./session.json} E=./welite_extspam.txt
A="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36"
W=login.wx.qq.com
declare -A CN_ CN_R
declare -A SEEN=()
SEEN_MAX=200
STOP=0

_get(){ curl -s -b "$J" -c "$J" -A "$A" --connect-timeout 10 -m 30 "$1?$2"; }
_post(){ curl -s -b "$J" -c "$J" -A "$A" --connect-timeout 10 -m 30 -H "Content-Type: application/json;charset=UTF-8" -d "$2" "$1${3:+?$3}"; }
_extract(){ echo "$2"|grep -oP "${1//./\\.}\s*=\s*\"?\K[^\"';]+"|head -1; }
_base_req(){ jq -n --arg u "$UIN" --arg s "$SID" --arg k "$SKEY" --arg d "$D" '{Uin:($u|tonumber),Sid:$s,Skey:$k,DeviceID:$d}'; }
_sync_keys(){ jq -c '[.SyncKey.List[]?|{Key,Val}]'; }

_load(){
  [ -f "$F" ] || return 1
  local data
  data=$(jq -r '[.uin,.sid,.skey,.pass_ticket,.sync_key,.device_id,.base_host,.base_origin,.self_id]|@tsv' "$F")
  IFS=$'\t' read -r UIN SID SKEY PASS_TICKET SYNC_KEY D BASE_HOST BASE_ORIGIN SELF_ID <<< "$data"
}
_save(){
  local t=$(mktemp); chmod 600 "$t"
  jq -n --arg u "$UIN" --arg s "$SID" --arg k "$SKEY" --arg p "$PASS_TICKET" \
    --arg y "$SYNC_KEY" --arg d "$D" --arg h "$BASE_HOST" --arg o "$BASE_ORIGIN" --arg i "$SELF_ID" \
    '{uin:$u,sid:$s,skey:$k,pass_ticket:$p,sync_key:$y,device_id:$d,base_host:$h,base_origin:$o,self_id:$i}' > "$t" \
    && mv "$t" "$F"
}
_build_cache(){
  CN_=(); CN_R=()
  while IFS=$'\t' read -r u n r; do
    [ -z "$u" ] && continue
    CN_["$u"]="${n:-$u}"
    [ -n "$r" ] && CN_R["$u"]="$r"
  done < <(jq -r '.[]|[.username,.nickname//"",.remark//""]|@tsv' "$C" 2>/dev/null)
}
_name(){
  local u="${1:?}"
  if [ "${CN_R[$u]}" ]; then echo "${CN_R[$u]}"
  elif [ "${CN_[$u]}" ]; then echo "${CN_[$u]}"
  else echo "$u"
  fi
}
_resolve(){
  local r=$(jq -r --arg n "$1" '.[]|select(.nickname==$n or .remark==$n or .username==$n)|.username' "$C" 2>/dev/null|head -1)
  [ -n "$r" ] && { echo "$r"; return; }
  jq -r --arg n "${1,,}" '.[]|select((.nickname|ascii_downcase|contains($n))or(.remark|ascii_downcase|contains($n)))|.username' "$C" 2>/dev/null|head -1
}

_contacts(){
  local seq=0 rv
  while true; do
    rv=$(curl -s -b "$J" -c "$J" -A "$A" --connect-timeout 10 -m 30 \
      -H "Cookie: wxuin=$UIN; wxsid=$SID; pass_ticket=$PASS_TICKET; pgv_pvi=$RANDOM; pgv_si=s$RANDOM" \
      "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxgetcontact?r=$(date +%s%3N)&seq=$seq&skey=$SKEY")
    [ -z "$rv" ] && break
    [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$rv")" != 0 ] && break
    local t=$(mktemp)
    jq -s '.[0]+.[1]|unique_by(.username)' "$C" \
      <(echo "$rv"|jq '[(.MemberList//.ContactList)[]?|{username:.UserName,nickname:(.NickName//""),remark:(.RemarkName//"")}]') > "$t" \
      && mv "$t" "$C"
    seq=$(jq -r '.Seq//0'<<<"$rv")
    [ "$seq" = 0 ] && break
  done
  chmod 600 "$C"
  _build_cache
}

_init(){
  local br=$(_base_req) rv
  rv=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxinit" "{\"BaseRequest\":$br}" \
    "pass_ticket=$PASS_TICKET&r=$(( $(date +%s%3N) / -1579 ))")
  ret=$(jq -r '.BaseResponse.Ret'<<<"$rv")
  [ "$ret" != 0 ] && { echo "init: Ret=$ret" >&2; return 1; }
  SELF_ID=$(jq -r '.User.UserName//""'<<<"$rv")
  SYNC_KEY=$(echo "$rv"|_sync_keys)
  echo "$rv"|jq '[.ContactList[]?|{username:.UserName,nickname:(.NickName//""),remark:(.RemarkName//"")}]' > "$C"
  _post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxstatusnotify" \
    "{\"BaseRequest\":$br,\"Code\":3,\"FromUserName\":$(jq -R<<<"$SELF_ID"),\"ToUserName\":$(jq -R<<<"$SELF_ID"),\"ClientMsgId\":$(date +%s)}" \
    "lang=zh_CN" >/dev/null
  _contacts
  _check || { echo "init: session expired" >&2; return 1; }
}

_check(){
  local ph
  if [[ "$BASE_HOST" =~ ^([^.]+)(\.qq\.com|\.wechat\.com)$ ]]; then
    ph="webpush.${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  else ph="webpush.weixin.qq.com"; fi
  local sr=$(_get "https://$ph/cgi-bin/mmwebwx-bin/synccheck" \
    "r=$(date +%s)&sid=$SID&uin=$UIN&skey=$SKEY&deviceid=$D&synckey=$(echo "$SYNC_KEY"|jq -r '[.[]|"\(.Key)_\(.Val)"]|join("|")')&_=$(date +%s)")
  local rc=$(echo "$sr"|grep -oP 'retcode\s*[=:]\s*"?\K\d+')
  [ "$rc" = 1100 ]||[ "$rc" = 1101 ] || return 0
  return 1
}

login(){
  rm -f "$J"
  D="e$(head -c14 /dev/urandom|od -A n -t x1|tr -d ' \n')"
  local r u
  r=$(_post "https://$W/jslogin" "" "appid=wx782c26e4c19acffb&fun=new&lang=zh_CN&redirect_uri=https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?mod=desktop")
  [ "$(_extract "window.QRLogin.code" "$r")" != 200 ] && { echo "getUUID failed" >&2; return 1; }
  u=$(_extract "window.QRLogin.uuid" "$r"); [ -z "$u" ] && { echo "getUUID: no uuid" >&2; return 1; }
  local qr="https://login.weixin.qq.com/l/$u"
  if command -v qrencode &>/dev/null; then
    echo "welite: scan with WeChat:" >&2
    qrencode -t ANSIUTF8 "$qr" 2>/dev/null || qrencode -t UTF8 "$qr" 2>/dev/null || echo "$qr" >&2
  else echo "welite: scan $qr" >&2; fi

  local redir="" wc eu
  eu=$(printf '%s' "$u" | jq -sRr @uri)
  while [ -z "$redir" ]; do
    sleep 2
    r=$(_get "https://$W/cgi-bin/mmwebwx-bin/login" "tip=0&uuid=$eu&loginicon=true&r=$((~$(date +%s)))")
    wc=$(_extract "window.code" "$r")
    case "$wc" in
      200) redir=$(_extract "window.redirect_uri" "$r"); [ -z "$redir" ] && { echo "no redirect_uri" >&2; return 1; } ;;
      201) echo "welite: scanned, waiting for confirm..." >&2 ;;
    esac
  done

  local tmp=$(mktemp); trap 'rm -f "$tmp"' RETURN
  local extspam=$(cat "$E" 2>/dev/null) || extspam=""
  local hc=$(curl -s -o "$tmp" -w "%{http_code}" -c "$J" -b "$J" -A "$A" \
    --connect-timeout 10 -m 30 -H "client-version: 2.0.0" \
    ${extspam:+-H "extspam: $extspam"} \
    -H "referer: https://wx.qq.com/?&lang=zh_CN&target=t" \
    --max-redirs 0 "$redir" 2>/dev/null)
  [ "$hc" != 301 ] && [ "$hc" != 302 ] && { echo "login: unexpected status $hc" >&2; return 1; }
  chmod 600 "$J"
  local bd=$(cat "$tmp")
  SKEY=$(echo "$bd"|xmllint --html --xpath 'string(//skey)' - 2>/dev/null)
  SID=$(echo "$bd"|xmllint --html --xpath 'string(//wxsid)' - 2>/dev/null)
  UIN=$(echo "$bd"|xmllint --html --xpath 'string(//wxuin)' - 2>/dev/null)
  PASS_TICKET=$(echo "$bd"|xmllint --html --xpath 'string(//pass_ticket)' - 2>/dev/null)
  [ -z "$SKEY" ]||[ -z "$SID" ]||[ -z "$UIN" ] && { echo "login: missing credentials" >&2; return 1; }
  BASE_HOST=$(echo "$redir"|sed 's|https://||;s|/.*||')
  BASE_ORIGIN="https://$BASE_HOST"
  _init && _save && echo "welite: ready (uid=$SELF_ID)" >&2
}

restart(){
  [ -z "$UIN" ]||[ -z "$SID" ] && { echo "restart: no saved session" >&2; return 1; }
  _init && _save && echo "welite: ready (uid=$SELF_ID)" >&2
}

sync(){
  local ph delay=1
  if [[ "$BASE_HOST" =~ ^([^.]+)(\.qq\.com|\.wechat\.com)$ ]]; then
    ph="webpush.${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  else ph="webpush.weixin.qq.com"; fi
  while [ "$STOP" = 0 ]; do
    local sr rc sl
    sr=$(_get "https://$ph/cgi-bin/mmwebwx-bin/synccheck" \
      "r=$(date +%s)&sid=$SID&uin=$UIN&skey=$SKEY&deviceid=$D&synckey=$(echo "$SYNC_KEY"|jq -r '[.[]|"\(.Key)_\(.Val)"]|join("|")')&_=$(date +%s)")
    if [ -z "$sr" ]; then
      sleep $((delay>30?30:delay)); delay=$((delay*2)); continue
    fi
    delay=1
    rc=$(echo "$sr"|grep -oP 'retcode\s*[=:]\s*"?\K\d+')
    sl=$(echo "$sr"|grep -oP 'selector\s*[=:]\s*"?\K\d+')
    case "$rc" in 1100|1101) echo "welite: sync: session expired" >&2; break ;; esac
    [ "$sl" = 0 ] && continue

    local sb=$(jq -n --arg u "$UIN" --arg s "$SID" --arg k "$SKEY" --arg d "$D" --argjson skl "$SYNC_KEY" \
      '{BaseRequest:{Uin:($u|tonumber),Sid:$s,Skey:$k,DeviceID:$d},SyncKey:{Count:($skl|length),List:$skl},rr:'$((~$(date +%s)))'}')
    sr=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsync" "$sb" "sid=$SID&skey=$SKEY&pass_ticket=$PASS_TICKET&lang=zh_CN")
    [ -z "$sr" ] && { sleep 1; continue; }
    [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$sr")" = 1101 ] && { echo "welite: sync: session expired" >&2; break; }
    SYNC_KEY=$(echo "$sr"|_sync_keys)
    _save

    while IFS= read -r m; do
      [ -z "$m" ] && continue
      [ "$(jq -r '.MsgType//0'<<<"$m")" != 1 ] && continue
      [ "$(jq -r '.FromUserName//""'<<<"$m")" = "$SELF_ID" ] && continue
      local mid=$(jq -r '.MsgId//""'<<<"$m")
      [ -n "$mid" ] && [ "${SEEN[$mid]}" ] && continue
      [ -n "$mid" ] && SEEN[$mid]=1
      local fr=$(jq -r '.FromUserName//""'<<<"$m")
      local tx=$(sed 's/<br\/>/\n/g;s/<[^>]*>//g;s/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g;s/&quot;/"/g'<<<"$(jq -r '.Content//""'<<<"$m")")
      local sn=$(_name "$fr")
      if [[ "$fr" == @@* ]]; then
        local mi=""
        [[ "$tx" == @*:* ]] && { mi="${tx#@}"; mi="${mi%%:*}"; tx="${tx#*:}"; tx="${tx#:}"; tx="${tx## }"; }
        echo "[$sn${mi:+/$(_name "$mi")}] $tx" >&2
      else
        echo "[$sn] $tx" >&2
        notify-send -- "$sn" "$tx" 2>/dev/null &
      fi
      [ ${#SEEN[@]} -gt $SEEN_MAX ] && { local ks=("${!SEEN[@]}"); for k in "${ks[@]::$(( ${#ks[@]} - SEEN_MAX/2 ))}"; do unset SEEN[$k]; done; }
    done <<< "$(echo "$sr"|jq -c '.AddMsgList[]?')"
  done
}

send(){
  local t="$1" x="$2" cid=$(( $(date +%s) * 1000 + RANDOM % 1000 ))
  local b=$(jq -n --arg u "$UIN" --arg s "$SID" --arg k "$SKEY" --arg d "$D" \
    --arg f "$SELF_ID" --arg t "$t" --arg x "$x" --argjson c "$cid" \
    '{BaseRequest:{Uin:($u|tonumber),Sid:$s,Skey:$k,DeviceID:$d},Scene:0,
      Msg:{Type:1,Content:$x,FromUserName:$f,ToUserName:$t,ClientMsgId:$c,LocalID:$c}}')
  local r=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsendmsg" "$b" "pass_ticket=$PASS_TICKET")
  [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$r")" = 0 ]
}

handle(){
  _load
  _build_cache
  local c; IFS= read -r c
  [ -z "$c" ] && { echo ERR; exit; }
  case "$c" in
    LIST) jq -r '.[]|if .remark!="" then .remark elif .nickname!="" then .nickname else .username end' "$C" 2>/dev/null ;;
    SEND*)
      local n="${c#SEND }"; n="${n%% *}"; local x="${c#SEND $n }"; x="${x## }"
      [ -z "$n" ]||[ -z "$x" ] && { echo ERR; exit; }
      local u=$(_resolve "$n"); [ -z "$u" ] && { echo ERR; exit; }
      send "$u" "$x" && echo OK || echo ERR ;;
    *) echo ERR ;;
  esac
}

daemon(){
  trap 'STOP=1; rm -f "$S"' INT TERM
  trap 'STOP=1' USR1
  rm -f "$S"
  _load 2>/dev/null || true
  if [ -n "$UIN" ] && [ -n "$SID" ]; then restart || login || exit 1; else login || exit 1; fi
  socat UNIX-LISTEN:"$S",fork,reuseaddr EXEC:"$(readlink -f "$0") handle $F",nofork 2>/dev/null &
  local sp=$!
  while [ "$STOP" = 0 ]; do
    sync
    [ "$STOP" = 1 ] && break
    echo "welite: reconnecting..." >&2
    _load 2>/dev/null || true
    if [ -n "$UIN" ] && [ -n "$SID" ]; then restart || login || exit 1; else login || exit 1; fi
  done
  kill $sp 2>/dev/null
  rm -f "$S"
}

cmd(){ echo "$1"|socat - UNIX-CONNECT:"$S" 2>/dev/null; }
client(){
  [ $# -lt 1 ]||[ "$1" = -h ]||[ "$1" = --help ]&&{
    echo "Usage: $0 -d               (daemon)"
    echo "       $0 <nick> <text..>  (send)"
    echo "       $0 -l                (list)"; exit 1; }
  [ "$1" = -l ] && { cmd LIST; return; }
  [ $# -lt 2 ] && { echo "welite: <nick> <text>" >&2; exit 1; }
  local r=$(cmd "SEND $1 ${*:2}"); [ "${r:0:2}" = OK ]
}

case "$1" in
  -d) F="${2:-./session.json}"; daemon ;;
  handle) F="${2:-./session.json}"; handle ;;
  *) client "$@" ;;
esac
