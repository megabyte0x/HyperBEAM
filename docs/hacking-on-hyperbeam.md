# Hacking on HyperBEAM

The HyperBEAM codebase has a number of mechanism to make building upon it
easier. Here is a quick rundown of the must-knows:

## Starting HyperBEAM

You can start HyperBEAM with rebar3 as follows:
```
	rebar3 shell
```

This will drop you into an Erlang shell with all of the necessary modules 
loaded. Additionally, starting HyperBEAM this way will initialize its HTTP
server, such that you can begin to send requests to it. There are a few helpful
shortcut options you can provide and environment variables:

- `HB_STORE=dir`: Set a local filesystem store as HB's only location to read and 
write to. This can be helpful for separating multiple nodes running on the same
host/in the same directory.
- `HB_KEY=file`: The key that HyperBEAM will use to sign all messages on the 
node, unless otherwise indicated.
- `HB_PORT=[number]`: The port number HB will use to register its HTTP server.

Check out `hb_opts` for the full list.

## Running the tests

In order to run HyperBEAM's built-in tests, start eunit with rebar3 as follows:

```
	rebar3 eunit
```

This should run all of the tests in every HyperBEAM module. If you would like to
run only tests from a specific set of modules, just add `--module=list,of,mods`.
To run only a specific test use `--test=your_module:your_test`.

Do not send a PR in which the tests do not pass.

## Event logging and debugging

HyperBEAM provides a flexible mechanism for writing debug prints to the CLI
(and later, perhaps, other logging systems). Simply call `?event(term())` and
your term will be processed through the logging mechanisms.

You can control the information that is displayed in the command-line log
by either setting `debug_print` in `hb_opts` globally, or passing the 
`HB_PRINT=[setting]` environment variable when you start HyperBEAM. Your 
`[setting]` can be either `true` (or `1` via the CLI), or a list of module
names that you would like to see the prints for. For example, if you would like
to analyze would HB's path management `dev_message` modules are doing while you
run your tests, just execute:

```
	HB_PRINT=hb_path,hb_converge rebar3 eunit --module=your_mod
```

The HB printing system is reasonably intelligent. It has a custom
pretty-printer that can recognize a few useful types of terms in the
environment:

- Messages
- Arweave transactions and data items
- Tuples of form `{Status, Term}`
- Binary IDs

These terms will be printed along with other basic debugging info (modules,
functions, line numbers).

Additionally, HyperBEAM has a custom pretty-printer for stacktraces that is 
aware of the boundaries of the machine. It will print traces until the first
stack frame that references a module prefix that it is unaware of. By default,
it will print all frames that start with `hb_`, `ar_`, and `dev_`. You can 
change this behavior via the options found in `hb_opts`.

## Helpful utilities

If you would like to re-build HyperBEAM in-place, while it is running, just 
run `hb:build()`. This will invoke `rebar3` and build any modules changed 
since the last invocation.

Happy hacking!