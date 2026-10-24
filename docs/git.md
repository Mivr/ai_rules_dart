# Host git requirements for `pub` git packages

Every git package fetch checks the host `git` version first (`git version`)
and fails below **2.32**. The error names the minimum and the version found;
an unparsable version fails closed.

Why 2.32: the fetch isolation points `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_SYSTEM` at an empty file for local repositories, and support for
those environment selectors landed in git 2.32. Older git silently ignores
them and reads the host's files instead, so fetching there would run under
host configuration — including a host-global `uploadpack.packObjectsHook`.

Whether a fetch is local is decided on the URL git will actually fetch,
after the host's `url.<base>.insteadOf` rewrites: a remote lock URL the
host rewrites to a local repository fetches with the same isolation as a
lock URL that is local to begin with — no host config file is read, the
inline-config channel is unset, and no host hook of any kind runs. Remote
fetches keep inheriting the host's transport configuration (credentials,
`insteadOf` rewrites, proxies) on purpose.
