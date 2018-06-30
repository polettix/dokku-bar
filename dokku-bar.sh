#!/bin/bash

bar_is_true() {
   case "$1" in
      (y|yes|Y|Yes|YES|t|true|T|True|TRUE|1)
         return 0
         ;;
      (*)
         return 1
         ;;
   esac
}

bar_pd() {
   ssh "$DOKKU_HOST" "$@"
}

bar_log() {
   printf '%s\n' "$*" >&2
}

bar_help() {
   cat >&2 <<'END'
CHECK_ENV
   (boolean) only print out environment for a command
DISABLE_CHECKS
   (boolean) set whether to disable checks in restored applications
DOKKU_HOST
   hostname/IP address of target dokku installation
DUMPDIR
   the directory where the backup is saved/taken
KEEP_RUNNING
   (boolean) set whether to stop applications before backup or not
REMOTE
   name of the remote to set in repositories for restored apps
   Defaults to `dokku`. Skips creating it in case it already exists
   so BE CAREFUL!

Booleans default to false, true is y|yes|Y|Yes|YES|t|true|T|True|TRUE|1
END
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

bar_backup_start_apps() {
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
   [[ -n "$1" ]] && DUMPDIR="$1"
   [[ -z "$DUMPDIR" ]] && DUMPDIR="DOKKU-$(date +'%Y%m%d-%H%M%S')"
   [[ ! -d "$DUMPDIR" ]] && mkdir "$DUMPDIR"
   if [[ ! -d "$DUMPDIR" ]] ; then
      bar_log "nothing to do for dumpdir <$DUMPDIR>"
      return 1
   fi
   export DUMPDIR="$(readlink -f "$DUMPDIR")"
   if bar_is_true "$CHECK_ENV" ; then
      env
      return 1
   fi
   {
      bar_is_true "$KEEP_RUNNING" || bar_backup_stop_apps
      bar_backup_global_configs
      bar_backup_storage
      bar_backup_postgres
      bar_backup_apps
      bar_backup_letsencrypt
      bar_is_true "$KEEP_RUNNING" || bar_backup_start_apps
   } >&2
   printf '%s\n' "export DUMPDIR='$DUMPDIR'"
}

bar_restore_generic_configs() {
   local CONFIGS
   CONFIGS="$(<"$DUMPDIR/global.env")"
   bar_pd config:set --global $CONFIGS
}

bar_restore_create_app() {
   local NAME="$1" CONFIGS VOLUME
   bar_log "-----> Create app <$NAME>"
   bar_pd apps:exists "$NAME" </dev/null && return 0
   bar_pd apps:create "$NAME"
   CONFIGS="$(<"$DUMPDIR/$NAME.env")"
   bar_pd config:set "$NAME" $CONFIGS
   bar_is_true "$DISABLE_CHECKS" && bar_pd checks:skip "$NAME"
   cat "$DUMPDIR/$NAME.vol.list" \
      | while read VOLUME ; do
         bar_pd storage:mount "$NAME" "$VOLUME"
      done
}

bar_restore_create_apps() {
   bar_log '-----> Create apps'
   cat "$DUMPDIR/apps.list" \
      | while read NAME ; do
         bar_restore_create_app "$NAME" </dev/null
      done
}

bar_restore_storage() {
   [[ -s "$DUMPDIR/storage.tar.gz" ]] || return 0
   bar_log '-----> Restore storage'
   ssh "root@$DOKKU_HOST" tar xzC /var/lib/dokku/data/storage . \
      < "$DUMPDIR/storage.tar.gz"
}

bar_restore_postgres_service() {
   local NAME="$1" APPNAME
   bar_log "-----> Restore postgres service <$NAME>"
   bar_pd postgres:create "$NAME"
   bar_pd postgres:import "$NAME" <"$DUMPDIR/$NAME.pgdmp"
   cat "$DUMPDIR/$NAME.links" \
      | while read APPNAME ; do
         [[ -n "$APPNAME" ]] || continue
         bar_pd postgres:link "$NAME" "$APPNAME"
      done
}

bar_restore_postgres() {
   local NAME APPNAME
   bar_log '-----> Restore postgres services'
   cat "$DUMPDIR/postgres.list" \
      | while read NAME ; do
         bar_restore_postgres_service "$NAME" </dev/null
      done
}

bar_restore_letsencrypt() {
   local NAME
   bar_log '-----> Restore letsencrypt'
   cat "$DUMPDIR/letsencrypt.list" \
      | while read NAME ; do
         [[ -n "$NAME" ]] && bar_pd letsencrypt "$NAME" </dev/null
      done
   bar_pd letsencrypt:cron-job --add
}

bar_restore_app() {
   local NAME="$1"
   local REMOTE="${REMOTE:-dokku}"
   (
      bar_log "-----> Restore app <$NAME>"
      cd "$NAME"
      SCALE="$(<"$DUMPDIR/$NAME.scale")"
      bar_pd ps:scale "$NAME" $SCALE
      BRANCH="$(git symbolic-ref HEAD | sed 's#.*/##')"
      git remote | grep "\\<$REMOTE\\>" >/dev/null 2>&1 \
         || git remote add "$REMOTE" "dokku@$DOKKU_HOST:$NAME"
      git push "$REMOTE" "$BRANCH:master"
   )
}

bar_restore_apps() {
   local NAME
   bar_log '-----> Restore apps'
   cat "$DUMPDIR/apps.list" \
      | while read NAME ; do
         bar_restore_app "$NAME" </dev/null
      done
}

bar_restore_generic_configs() {
   local CONFIGS="$(<"$DUMPDIR/global.env")"
   bar_pd config:set --global $CONFIGS
}

bar_set_domain() {
   [[ -n "DOMAIN" ]] && bar_pd domains:set-global "$DOMAIN"
}

bar_restore() {
   local DUMPDIR="$DUMPDIR"
   [[ -n "$RESTORE_DUMPDIR" ]] && DUMPDIR="$RESTORE_DUMPDIR"
   [[ -n "$1" ]] && DUMPDIR="$1"
   if [[ ! -d "$DUMPDIR" ]] ; then
      bar_log "no accessible dumpdir"
      return 1
   fi
   DUMPDIR="$(readlink -f "$DUMPDIR")"
   local DOKKU_HOST="$DOKKU_HOST"
   [[ -n "DOKKU_RESTORE_HOST" ]] && DOKKU_HOST="$DOKKU_RESTORE_HOST"
   export DUMPDIR DOKKU_HOST
   if bar_is_true "$CHECK_ENV" ; then
      env
      return 1
   fi
   bar_restore_generic_configs
   bar_set_domain
   bar_restore_storage
   bar_restore_create_apps
   bar_restore_postgres
   bar_restore_apps
   bar_restore_letsencrypt
}

__BAR_MAIN__() {
   [[ -r ./dokku-bar.env ]] && . ./dokku-bar.env
   case "$1" in
      (backup)
         bar_backup "$2"
         ;;
      (restore)
         bar_restore "$2"
         ;;
      (env)
         env
         ;;
      (*)
         bar_log ''
         bar_log "$0 [backup] [restore] [env]"
         bar_log ''
         bar_help
         bar_log ''
         ;;
   esac
}

# check for sourcing, otherwise run
if [[ "${BASH_SOURCE[0]}" = "$0" ]] ; then
   __BAR_MAIN__ "$@"
else
   unset __BAR_MAIN__
fi
