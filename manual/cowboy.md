cowboy
======

The `cowboy` module provides convenience functions for
manipulating Ranch listeners.

Types
-----

None.

Exports
-------

**start_http(Ref, NbAcceptors, TransOpts, ProtoOpts) -> {ok, pid()}**

> Types:
>  *  Ref = ranch:ref()
>  *  NbAcceptors = non_neg_integer()
>  *  TransOpts = ranch_tcp:opts()
>  *  ProtoOpts = cowboy_protocol:opts()
>
> Start listening for HTTP connections. Returns the pid for this
> listener's supervisor.

**start_https(Ref, NbAcceptors, TransOpts, ProtoOpts) -> {ok, pid()}**

> Types:
>  *  Ref = ranch:ref()
>  *  NbAcceptors = non_neg_integer()
>  *  TransOpts = ranch_ssl:opts()
>  *  ProtoOpts = cowboy_protocol:opts()
>
> Start listening for HTTPS connections. Returns the pid for this
> listener's supervisor.

**stop_listener(Ref) -> ok**

> Types:
>  *  Ref = ranch:ref()
>
> Stop a previously started listener.

**set_env(Ref, Name, Value) -> ok**

> Types:
>  *  Ref = ranch:ref()
>  *  Name = atom()
>  *  Value = any()
>
> Set or update an environment value for an already running listener.
> This will take effect on all subsequent connections.

See also
--------

The [Ranch guide](http://ninenines.eu/docs/en/ranch/HEAD/guide)
provides detailed information about how listeners work.
