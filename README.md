# Backup/Restore tool for Dokku

This works for my setup, your mileage may vary.

## Setup

I have this:

- this repository checked out in `/path/to/dokku-bar`
- a directory `/path/to/doma.in` where I keep the repos for all the stuff
  that is deployed on `doma.in`
- an environment file `/path/to/doma.in/dokku-bar.env` like this:

        #!/bin/bash
        : ${DISABLE_CHECKS:=yes}
        : ${DOKKU_HOST:=doma.in}
        : ${DOKKU_RESTORE_HOST:="$DOKKU_HOST"}
        : ${DOMAIN:=doma.in}
        : ${RESTORE_DUMPDIR:=/path/to/doma.in/LAST}
        : ${KEEP_RUNNING:=no}
        : ${REMOTE:=dokku}
        export DISABLE_CHECKS DOKKU_HOST DOKKU_RESTORE_HOST DOMAIN KEEP_RUNNING REMOTE

    (Well, actually the `DOKKU_HOST` is set to a name that has a
    configuration inside `~/.ssh/config`)

- a running instance on [DigitalOcean][] has a floating IP that is
  configured as a wildcard in the DNS configuration for `doma.in`.

## Backup

For a backup I do this:

    $ cd /path/to/doma.in
    $ /path/to/dokku-bar/dokku-bar.sh backup
    #
    # ... some log lines on STDERR, and eventually something like this on
    # STDOUT:
    #
    export DUMPDIR='/path/to/doma.in/DOKKU-20180630-105238'
    $ rm -f LAST
    $ ln -s DOKKU-20180630-105238 LAST

## Restore

For a restore, the current procedure has a downtime that is fine for me:

- spin up a new droplet in [DigitalOcean][] installing [Dokku][] according
  to the unattended procedure ([see here for a suitable *cloud-init*
  file][dokku-unattended], just change `example.com` to
  your domain)
- wait for [Dokku][] to be up and running on the new droplet (check
  `/var/log/cloud-init-output.log` to track advance)
- re-assign the floating IP to this new droplet (this is where the
  downtime starts!)
- start the restore procedure:

        $ cd /path/to/doma.in
        $ /path/to/dokku-bar/dokku-bar.sh restore

At the end of the restore all services should be up and running again.


[DigitalOcean]: https://www.digitalocean.com/
[Dokku]: http://dokku.viewdocs.io/dokku/
[dokku-unattended]: https://github.com/polettix/dokku-boot/blob/master/cloud-init-unattended.sh
