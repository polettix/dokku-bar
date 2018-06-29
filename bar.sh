#!/bin/bash

bar_pd() {
   ssh "$DOKKU_HOST" "$@"
}

bar_d() {
   dokku "$@"
}

bar_log() {
   printf '%s\n' "$*" >&2
}

bar_app_name() {
   (
      while [[ "$PWD" != '/' ]] && ! [[ -d .git ]] ; do cd .. ; done
      [[ -d .git ]] && basename "$PWD"
   )
}

bar_linked_postgres() {
   local NAME REST
   dokku postgres:list \
      | sed -e 1d \
      | while read NAME REST ; do
            dokku postgres:info "$NAME" --links </dev/null \
            | grep "\\<$APP\\>" >/dev/null 2>&1 \
            && printf '%s\n' "$NAME"
      done
}

# this operation is cross-application
bar_backup_postgres() {
   local NAME REST
   >"$DUMPDIR/postgres.list"
   bar_pd postgres:list \
      | sed -e 1d \
      | while read NAME REST ; do
         bar_log "postgres <$NAME>"
         printf '%s\n' "$NAME" >>"$DUMPDIR/postgres.list"
         bar_pd postgres:export "$NAME" > "$DUMPDIR/$NAME.pgdmp"
         bar_pd postgres:info "$NAME" --links  > "$DUMPDIR/$NAME.links"
      done
}

bar_config_inline() {
   sed -e 's/^export //' \
   | grep -v "$1" \
   | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g'
}

bar_backup_global_configs() {
   local NAME REST
   bar_pd config:export --global \
      | bar_config_inline '^$' > "$DUMPDIR/global.env"
}

bar_backup_stop_apps() {
   bar_pd ps:stopall
}

bar_backup_start_app() {
   bar_pd ps:startall
}

bar_backup_apps() {
   local NAME SPEC REST CONTAINER MNT VOL
   bar_log "apps"
   >"$DUMPDIR/apps.list"
   bar_pd apps:list \
      | sed -e 1d \
      | while read NAME REST ; do
      {
         bar_log "config <$NAME>"
         printf '%s\n' "$NAME" >>"$DUMPDIR/apps.list"
         bar_pd config:export "$NAME" \
            | bar_config_inline '^\(DOKKU_\|GIT_REV=\|DATABASE_URL=\)' \
            > "$DUMPDIR/$NAME.env"
         bar_pd ps:scale "$NAME" \
            | sed '0,/^-*> --*/d;s/^-*> //;s/  */=/;s/ *$//' \
            | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g' \
            > "$DUMPDIR/$NAME.scale"
         CONTAINER="$(
            dokku ps:report "$NAME" \
               | sed -n '/\<Status\>/{s/.*Status \([^.]*\)\..*/\1/p;q}'
         )"
         bar_pd storage:list "$NAME" \
            | sed -e '1d;s/^ *//' \
            >"$DUMPDIR/$NAME.vol.list"
      } </dev/null
      done
}

bar_backup_storage() {
   ssh "root@$DOKKU_HOST" tar czC /var/lib/dokku/data/storage . \
      > "$DUMPDIR/storage.tar.gz"
}

bar_backup_letsencrypt() {
   local NAME REST
   bar_log "letsencrypt list"
   bar_pd letsencrypt:ls \
      | sed -e '1d;s/ .*//' > "$DUMPDIR/letsencrypt.list"
}

bar_backup() {
   local DUMPDIR
   [[ -n "$1" ]] && export DUMPDIR="$1"
   [[ -z "$DUMPDIR" ]] && DUMPDIR="DOKKU-$(date +'%Y%m%d-%H%M%S')"
   [[ ! -d "$DUMPDIR" ]] && mkdir "$DUMPDIR"
   if [[ ! -d "$DUMPDIR" ]] ; then
      bar_log "nothing to do for dumpdir <$DUMPDIR>"
      return 1
   fi
   export DUMPDIR="$(readlink -f "$DUMPDIR")"
   [ -n "$KEEP_RUNNING" ] || bar_backup_stop_apps
   bar_backup_global_configs
   bar_backup_storage
   bar_backup_postgres
   bar_backup_apps
   bar_backup_letsencrypt
   [ -n "$KEEP_RUNNING" ] || bar_backup_start_apps
   printf '%s\n' "$DUMPDIR"
}

bar_restore_generic_configs() {
   local CONFIGS
   CONFIGS="$(<"$DUMPDIR/global.env")"
   bar_pd config:set --global $CONFIGS
}

bar_restore_create_apps() {
   local NAME CONFIGS TARFILE VOLUME
   cat "$DUMPDIR/apps.list" \
      | while read NAME ; do
      {
         bar_pd apps:exists "$NAME" </dev/null && continue
         bar_pd apps:create "$NAME"
         CONFIGS="$(<"$DUMPDIR/$NAME.env")"
         bar_pd config:set "$NAME" $CONFIGS
         bar_pd checks:skip "$NAME"
         cat "$DUMPDIR/$NAME.vol.list" \
            | while read VOLUME ; do
               bar_pd storage:mount "$NAME" "$VOLUME"
            done
      } </dev/null
      done
}

bar_restore_storage() {
   ssh "root@$DOKKU_HOST" tar xzC /var/lib/dokku/data/storage . \
      < "$DUMPDIR/storage.tar.gz"
}

bar_restore_postgres() {
   local NAME APPNAME
   cat "$DUMPDIR/postgres.list" \
      | while read NAME ; do
      {
         bar_pd postgres:create "$NAME" </dev/null
         bar_pd postgres:import <"$DUMPDIR/$NAME.pgdmp"
         cat "$DUMPDIR/$NAME.links" \
            | while read APPNAME ; do
               [ -n "$APPNAME" ] || continue
               bar_pd postgres:link "$NAME" "$APPNAME"
            done
      } </dev/null
      done
}

bar_restore_letsencrypt() {
   local NAME
   cat "$DUMPDIR/letsencrypt.list" \
      | while read NAME ; do
         [ -n "$NAME" ] || continue
         bar_pd letsencrypt "$NAME"
      done
   bar_pd letsencrypt:cron-job --add
}

bar_restore_apps() {
   local NAME BRANCH SCALE
   : ${REMOTE:=dokku}
   cat "$DUMPDIR/apps.list" \
      | while read NAME ; do
      (
         bar_log "app restore <$NAME>"
         cd "$NAME"
         SCALE="$(<"$DUMPDIR/$NAME.scale")"
         bar_pd ps:scale "$NAME" $SCALE
         BRANCH="$(git symbolic-ref HEAD | sed 's#.*/##')"
         git remote add "$REMOTE" "dokku@$DOKKU_HOST:$NAME"
         git push "$REMOTE" "$BRANCH:master"
      ) </dev/null
      done
}

bar_restore_generic_configs() {
   local CONFIGS="$(<"$DUMPDIR/global.env")"
   bar_pd config:set --global $CONFIGS
}

bar_restore() {
   local DUMPDIR
   [ -n "$1" ] && export DUMPDIR="$1"
   if [[ ! -d "$DUMPDIR" ]] ; then
      bar_log "no accessible dumpdir"
      return 1
   fi
   bar_restore_generic_configs
   bar_restore_storage
   bar_restore_create_apps
   bar_restore_postgres
   bar_restore_apps
   bar_restore_letsencrypt
}

__BAR_MAIN__() {
   case "$1" in
      (backup)
         bar_backup "$2"
         ;;
      (restore)
         bar_restore "$2"
         ;;
      (*)
         bar_log "$0 [backup] [restore]"
         ;;
   esac
}

# check for sourcing, otherwise run
if [[ "${BASH_SOURCE[0]}" = "$0" ]] ; then
   __BAR_MAIN__ "$@"
else
   unset __BAR_MAIN__
fi
