#!/bin/bash
# welite.sh — WeChat Web API shell client
S=./welite.sock J=./welite_cookies.txt C=./welite_contacts.json F=${2:-./session.json} E=./welite_extspam.txt T=./welite_media
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
_file_host(){
  [[ "$1" =~ ^([^.]+)(\.qq\.com|\.wechat\.com)$ ]] && echo "file.${BASH_REMATCH[1]}${BASH_REMATCH[2]}" || echo "file.weixin.qq.com"
}

# emoji name lookup (from emoji_names.txt: index<TAB>name)
_emoji_name(){
  local i="$1"
  awk -F'\t' -v idx="$i" '$1==idx{print $2; exit}' emoji_names.txt 2>/dev/null || echo "表情"
}

_download_img(){
  local msgid="$1" dest="$2" thumb="$3"
  local params="MsgID=$msgid&skey=$SKEY"
  [ "$thumb" = 1 ] && params="$params&type=slave"
  curl -s -b "$J" -A "$A" --connect-timeout 10 -m 30 -o "$dest" \
    "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxgetmsgimg?$params"
}

_download_media(){
  local from="$1" mid="$2" name="$3" dest="$4"
  local wdt=$(grep 'webwx_data_ticket' "$J" | head -1 | awk '{print $NF}')
  local fh=$(_file_host "$BASE_HOST")
  curl -s -b "$J" -A "$A" --connect-timeout 10 -m 60 -o "$dest" \
    "https://$fh/cgi-bin/mmwebwx-bin/webwxgetmedia?sender=$from&mediaid=$mid&filename=$name&fromuser=$SELF_ID&pass_ticket=$PASS_TICKET&webwx_data_ticket=$wdt"
}

_download_video(){
  local msgid="$1" dest="$2"
  curl -s -b "$J" -A "$A" --connect-timeout 10 -m 120 -H "Range: bytes=0-" -o "$dest" \
    "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxgetvideo?MsgID=$msgid&skey=$SKEY"
}

_download_voice(){
  local msgid="$1" dest="$2"
  curl -s -b "$J" -A "$A" --connect-timeout 10 -m 60 -H "Range: bytes=0-" -o "$dest" \
    "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxgetvoice?MsgID=$msgid&skey=$SKEY"
}

_notify(){
  local title="$1" body="$2" icon="$3"
  local ic=""
  [ -f "$icon" ] && ic="$(readlink -f "$icon")"
  [ -n "$ic" ] && fyi -i "$ic" -- "$title" "$body" 2>/dev/null &
  [ -z "$ic" ] && fyi -- "$title" "$body" 2>/dev/null &
}

_preview(){
  local file="$1"
  chafa --size=20 "$file" 2>/dev/null
}

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
      [ "$(jq -r '.FromUserName//""'<<<"$m")" = "$SELF_ID" ] && continue
      local mid=$(jq -r '.MsgId//""'<<<"$m")
      [ -n "$mid" ] && [ "${SEEN[$mid]}" ] && continue
      [ -n "$mid" ] && SEEN[$mid]=1
      mkdir -p "$T"

      local fr=$(jq -r '.FromUserName//""'<<<"$m")
      local mt=$(jq -r '.MsgType//0'<<<"$m")
      local sn=$(_name "$fr")
      local tx content mediaid fname

      case "$mt" in
        1) # text
          tx=$(sed 's/<br\/>/\n/g;s/<[^>]*>//g;s/&amp;/\&/g;s/&lt;/</g;s/&gt;/>/g;s/&quot;/"/g'<<<"$(jq -r '.Content//""'<<<"$m")")
          # replace emoji <span class="emoji emojiN"> with [name] in text
          tx=$(sed -r 's/<span class="emoji emoji([0-9]+)"><\/span>/[emoji:\1]/g'<<<"$tx")
          while [[ "$tx" == *"[emoji:"* ]]; do
            local eid="${tx#*[emoji:}"; eid="${eid%%]*}"
            [ -z "$eid" ] && break
            local en=$(_emoji_name "$eid")
            tx="${tx//\[emoji:$eid\]/[$en]}"
          done
          ;;
        3) # image
          local f="$T/img_$mid.jpg"
          _download_img "$mid" "$f" 0
          [ ! -s "$f" ] && _download_img "$mid" "$f" 1
          if [ -s "$f" ]; then
            _preview "$f"
            _notify "$sn" "[Image]" "$f"
            tx="[Image]"
          else
            tx="[Image]"
          fi
          ;;
        47) # emoticon (try full-size only; official stickers have no downloadable asset)
          local f="$T/emo_$mid.png"
          _download_img "$mid" "$f" 0
          if [ -s "$f" ]; then
            _preview "$f"
            _notify "$sn" "[Emoticon]" "$f"
          fi
          tx="[Emoticon]"
          ;;
         43) # video — download thumbnail, MsgID for download
           local vf="$T/vid_$mid.jpg"
           _download_img "$mid" "$vf" 1
           if [ -s "$vf" ]; then
             _preview "$vf"
             _notify "$sn" "[Video]" "$vf"
           fi
           fname=$(jq -r '.FileName//""'<<<"$m")
           [ -z "$fname" ] && fname=$(jq -r '.EncryFileName//""'<<<"$m")
           tx="[Video] MsgID=$mid"
           [ -n "$fname" ] && tx="$tx file=$fname"
           ;;
         34) # voice
           fname=$(jq -r '.FileName//""'<<<"$m")
           tx="[Voice] MsgID=$mid"
           [ -n "$fname" ] && tx="$tx file=$fname"
           ;;
        49) # appmsg / file
          local amt=$(jq -r '.AppMsgType//0'<<<"$m")
          local url=$(jq -r '.Url//""'<<<"$m")
          content=$(jq -r '.Content//""'<<<"$m")
          mediaid=$(jq -r '.MediaId//""'<<<"$m")
          # file attachment (AppMsgType=6)
          if [ "$amt" = 6 ] && [ -z "$mediaid" ]; then
            mediaid=$(sed -n 's/.*<attachid>\([^<]*\)<\/attachid>.*/\1/p'<<<"$content")
          fi
          fname=$(jq -r '.FileName//""'<<<"$m")
          [ -z "$fname" ] && fname=$(sed -n 's/.*<title><!\[CDATA\[\([^\]]*\)\]\]><\/title>.*/\1/p'<<<"$content")
          [ -z "$fname" ] && fname=$(sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p'<<<"$content")
          if [ -n "$url" ] && [ "$url" != "null" ]; then
            tx="[Link] $url"
          elif [ -n "$mediaid" ] && [ "$mediaid" != "null" ]; then
            tx="[File] mid=$mediaid file=$fname"
          else
            tx="[AppMsg]"
          fi
          ;;
        62) # microvideo
          mediaid=$(jq -r '.MediaId//""'<<<"$m")
          tx="[MicroVideo] mid=$mediaid"
          ;;
        *) tx="[Type:$mt]" ;;
      esac

      if [[ "$fr" == @@* ]]; then
        if [ "$mt" = 1 ] && [[ "$tx" == @*:* ]]; then
          local mi="${tx#@}"; mi="${mi%%:*}"; tx="${tx#*:}"; tx="${tx#:}"; tx="${tx## }"
          echo "[$sn/$(_name "$mi")] $tx" >&2
        else
          echo "[$sn] $tx" >&2
        fi
      else
        echo "[$sn] $tx" >&2
        _notify "$sn" "$tx" "" 
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

_sendfile(){
  local mid="$1" name="$2" size="$3" ext="$4" to="$5"
  local cid=$(( $(date +%s%3N) ))
  local br=$(_base_req)
  local content="<appmsg appid='wxeb7ec651dd0aefa9' sdkver=''><title>$name</title><des></des><action></action><type>6</type><content></content><url></url><lowurl></lowurl><appattach><totallen>$size</totallen><attachid>$mid</attachid><fileext>$ext</fileext></appattach><extinfo></extinfo></appmsg>"
  local b=$(jq -n --argjson br "$br" --argjson cid "$cid" \
    --arg x "$content" --arg f "$SELF_ID" --arg t "$to" \
    '{BaseRequest:$br,Scene:0,Msg:{Type:6,Content:$x,FromUserName:$f,ToUserName:$t,LocalID:$cid,ClientMsgId:$cid}}')
  local r=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsendappmsg" "$b" "pass_ticket=$PASS_TICKET&fun=async&f=json&lang=zh_CN")
  [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$r")" = 0 ]
}

_sendpic(){
  local mid="$1" to="$2"
  local cid=$(( $(date +%s%3N) ))
  local br=$(_base_req)
  local b=$(jq -n --argjson br "$br" --argjson cid "$cid" --arg mid "$mid" --arg f "$SELF_ID" --arg t "$to" \
    '{BaseRequest:$br,Scene:0,Msg:{Type:3,MediaId:$mid,FromUserName:$f,ToUserName:$t,LocalID:$cid,ClientMsgId:$cid}}')
  local r=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsendmsgimg" "$b" "pass_ticket=$PASS_TICKET&fun=async&f=json&lang=zh_CN")
  [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$r")" = 0 ]
}

_sendvideo(){
  local mid="$1" to="$2"
  local cid=$(( $(date +%s%3N) ))
  local br=$(_base_req)
  local b=$(jq -n --argjson br "$br" --argjson cid "$cid" --arg mid "$mid" --arg f "$SELF_ID" --arg t "$to" \
    '{BaseRequest:$br,Scene:0,Msg:{Type:43,MediaId:$mid,FromUserName:$f,ToUserName:$t,LocalID:$cid,ClientMsgId:$cid}}')
  local r=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsendvideomsg" "$b" "pass_ticket=$PASS_TICKET&fun=async&f=json&lang=zh_CN")
  [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$r")" = 0 ]
}

_sendemoticon(){
  local mid="$1" to="$2"
  local cid=$(( $(date +%s%3N) ))
  local br=$(_base_req)
  local b=$(jq -n --argjson br "$br" --argjson cid "$cid" --arg mid "$mid" --arg f "$SELF_ID" --arg t "$to" \
    '{BaseRequest:$br,Scene:0,Msg:{Type:47,EmojiFlag:2,MediaId:$mid,FromUserName:$f,ToUserName:$t,LocalID:$cid,ClientMsgId:$cid}}')
  local r=$(_post "$BASE_ORIGIN/cgi-bin/mmwebwx-bin/webwxsendemoticon" "$b" "pass_ticket=$PASS_TICKET&fun=sys&lang=zh_CN")
  [ "$(jq -r '.BaseResponse.Ret//-1'<<<"$r")" = 0 ]
}

_upload(){
  local file="$1" to="$2" CHUNK=$((512*1024))
  local fname="$(basename "$file")"
  local fsize="$(stat -c%s "$file")"
  local fext="${fname##*.}"; fext="${fext,,}"
  local fmime="application/octet-stream"
  case "$fext" in
    txt) fmime="text/plain";;
    pdf) fmime="application/pdf";;
    jpg|jpeg) fmime="image/jpeg";;
    png) fmime="image/png";;
    gif) fmime="image/gif";;
    mp4) fmime="video/mp4";;
    zip) fmime="application/zip";;
  esac
  local mediatype="doc"
  case "$fext" in bmp|jpeg|jpg|png) mediatype="pic";; mp4) mediatype="video";; esac
  local fmd5="$(md5sum "$file" | cut -d' ' -f1)"
  local cid=$(( $(date +%s%3N) ))
  local br=$(_base_req)
  local wdt=$(grep 'webwx_data_ticket' "$J" | head -1 | awk '{print $NF}')
  local fh=$(_file_host "$BASE_HOST")
  local chunks=$(( (fsize + CHUNK - 1) / CHUNK ))
  [ "$chunks" -le 0 ] && chunks=1 

  local i=0 offset=0 rv mid tmp curl_opts
  while [ "$i" -lt "$chunks" ]; do
    local remain=$((fsize - offset))
    local clen=$((remain < CHUNK ? remain : CHUNK))
    
    local umr=$(jq -n --argjson br "$br" --argjson cid "$cid" --argjson size "$fsize" \
      --arg f "$SELF_ID" --arg t "$to" --arg md5 "$fmd5" \
      --argjson start "$offset" --argjson dlen "$clen" \
      '{UploadType:2,BaseRequest:$br,ClientMediaId:$cid,TotalLen:$size,StartPos:$start,DataLen:$dlen,MediaType:4,FromUserName:$f,ToUserName:$t,FileMd5:$md5}')

    curl_opts=(
      -s -b "$J" -c "$J" -A "$A" --connect-timeout 30 -m 120
      -F "name=$fname" -F "type=$fmime"
      -F "lastModifiedDate=$(date -R)" -F "size=$fsize"
      -F "mediatype=$mediatype" -F "uploadmediarequest=$umr"
      -F "webwx_data_ticket=$wdt" -F "pass_ticket=$PASS_TICKET"
    )

    if [ "$chunks" -gt 1 ]; then
      curl_opts+=( -F "id=WU_FILE_0" -F "chunk=$i" -F "chunks=$chunks" )
      tmp=$(mktemp)
      tail -c +$((offset+1)) "$file" 2>/dev/null | head -c "$clen" > "$tmp"
      curl_opts+=( -F "filename=@$tmp;filename=$fname" )
    else
      curl_opts+=( -F "filename=@$file;filename=$fname" )
    fi

    rv=$(curl "${curl_opts[@]}" "https://$fh/cgi-bin/mmwebwx-bin/webwxuploadmedia?f=json")
    [ -n "$tmp" ] && rm -f "$tmp" && tmp=""
    local ret=$(jq -r '.BaseResponse.Ret//-1' <<<"$rv")
    if [ "$ret" != 0 ]; then
      echo "ERR: upload failed at chunk $i/$chunks, Ret=$ret" >&2
      return 1
    fi

    mid=$(jq -r '.MediaId' <<<"$rv")
    
    i=$((i+1))
    offset=$((offset + clen))
  done

  echo "$fname"$'\t'"$fsize"$'\t'"$fext"$'\t'"$mid"
}

handle(){
  _load
  _build_cache
  local c; IFS= read -r c
  [ -z "$c" ] && { echo ERR; exit; }
  case "$c" in
    LIST) jq -r '.[]|if .remark!="" then .remark elif .nickname!="" then .nickname else .username end' "$C" 2>/dev/null ;;
    DOWNLOAD*)
      local c2="${c#DOWNLOAD }"; local mid="${c2%% *}"; local fname="${c2#* }"
      [ -z "$mid" ] || [ -z "$fname" ] && { echo ERR; exit; }
      local ext="${fname##*.}"
      case "${ext,,}" in
        mp4) _download_video "$mid" "$fname" ;;
        mp3|wav|amr|silk) _download_voice "$mid" "$fname" ;;
        *) _download_media "$SELF_ID" "$mid" "$fname" "$fname" ;;
      esac
      [ -f "$fname" ] && echo OK || echo ERR ;; 
    SENDFILE*)
      local n="${c#SENDFILE }"; n="${n%% *}"; local fp="${c#SENDFILE $n }"; fp="${fp## }"
      { [ -z "$n" ] || [ -z "$fp" ] || [ ! -f "$fp" ]; } && { echo ERR; exit; }
      local u=$(_resolve "$n"); [ -z "$u" ] && { echo ERR; exit; }
      local info=$(_upload "$fp" "$u")
      [ $? != 0 ] && { echo ERR; exit; }
      IFS=$'\t' read -r fname fsize fext mid <<< "$info"
      case "$fext" in
        bmp|jpeg|jpg|png) _sendpic "$mid" "$u" && echo OK || echo ERR ;;
        gif) _sendemoticon "$mid" "$u" && echo OK || echo ERR ;;
        mp4) _sendvideo "$mid" "$u" && echo OK || echo ERR ;;
        *) _sendfile "$mid" "$fname" "$fsize" "$fext" "$u" && echo OK || echo ERR ;;
      esac ;;   
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
    echo "Usage: $0 -d                   (daemon)"
    echo "       $0 <nick> <text..>      (send text)"
    echo "       $0 -f <file> <nick>      (send file)"
    echo "       $0 -D <MediaId> <name>   (download media)"
    echo "       $0 -l                    (list)"; exit 1; }
  [ "$1" = -l ] && { cmd LIST; return; }
  [ "$1" = -D ] && {
    [ $# -lt 3 ] && { echo "welite: -D <MediaId> <FileName>" >&2; exit 1; }
    local r=$(cmd "DOWNLOAD $2 $3")
    [ "${r:0:2}" = OK ] && echo "downloaded: $3" && return 0
    echo "welite: $r" >&2; return 1; }
  [ "$1" = -f ] && {
    [ $# -lt 3 ] || [ ! -f "$2" ] && { echo "welite: -f <file> <nick>" >&2; exit 1; }
    local r=$(cmd "SENDFILE $3 $2")
    [ "${r:0:2}" = OK ] && echo "sent: $2 -> $3" && return 0
    echo "welite: $r" >&2; return 1; }
  [ $# -lt 2 ] && { echo "welite: <nick> <text>" >&2; exit 1; }
  local r=$(cmd "SEND $1 ${*:2}")
  [ "${r:0:2}" = OK ] && return 0
  echo "welite: $r" >&2; return 1
}

case "$1" in
  -d) F="${2:-./session.json}"; daemon ;;
  handle) F="${2:-./session.json}"; handle ;;
  *) client "$@" ;;
esac
