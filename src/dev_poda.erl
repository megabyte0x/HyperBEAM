-module(dev_poda).
-export([init/2, execute/3]).
-export([is_user_signed/1]).
-export([push/2]).
-include("include/ao.hrl").
-ao_debug(print).

%%% A simple exemplar decentralized proof of authority consensus algorithm
%%% for AO processes. This device is split into two flows, spanning three
%%% actions.
%%% 
%%% Execution flow:
%%% 1. Initialization.
%%% 2. Validation of incoming messages before execution.
%%% Attestation flow:
%%% 1. Adding attestations to results, either on a CU or MU.

%%% Execution flow: Initialization.

init(S, Params) ->
    {ok, S, extract_opts(Params)}.

extract_opts(Params) ->
    Authorities =
        lists:filtermap(
            fun({<<"Authority">>, Addr}) -> {true, Addr};
               (_) -> false end,
               Params
        ),
    {_, RawQuorum} = lists:keyfind(<<"Quorum">>, 1, Params),
    Quorum = binary_to_integer(RawQuorum),
    ?c({poda_authorities, Authorities}),
    ?no_prod(use_real_authority_addresses),
    Addr = ar_wallet:to_address(ao:wallet()),
    #{
        authorities =>
            Authorities ++ [ar_util:encode(Addr)],
        quorum => Quorum
    }.

%%% Execution flow: Pre-execution validation.

execute(Outer = #tx { data = #{ <<"Message">> := Msg } }, S = #{ pass := 1 }, Opts) ->
    case is_user_signed(Msg) of
        true ->
            {ok, S};
        false ->
            % For now, the message itself will be at `/Message/Message`.
            case validate(Msg, Opts) of
                true ->
                    ?c({poda_validated, ok}),
                    % Add the validations to the VFS.
                    Atts =
                        maps:to_list(
                            case Msg of 
                                #tx { data = #{ <<"Attestations">> := #tx { data = X } }} -> X;
                                #tx { data = #{ <<"Attestations">> := X }} -> X;
                                #{ <<"Attestations">> := X } -> X
                            end
                        ),
                    VFS1 =
                        lists:foldl(
                            fun({_, Attestation}, Acc) ->
                                Id = ar_bundles:signer(Attestation),
                                Encoded = ar_util:encode(Id),
                                maps:put(
                                    <<"/Attestations/", Encoded/binary>>,
                                    Attestation#tx.data,
                                    Acc
                                )
                            end,
                            maps:get(vfs, S, #{}),
                            Atts
                        ),
                    % Update the arg prefix to include the unwrapped message.
                    {ok, S#{ vfs => VFS1, arg_prefix =>
                        [
                            % Traverse two layers of `/Message/Message` to get
                            % the actual message, then replace `/Message` with it.
                            Outer#tx{
                                data = (Outer#tx.data)#{
                                    <<"Message">> => maps:get(<<"Message">>, Msg#tx.data)
                                }
                            }
                        ]
                    }};
                {false, Reason} -> return_error(S, Reason)
            end
    end;
execute(_M, S = #{ pass := 3, results := _Results }, _Opts) ->
    {ok, S};
execute(_M, S, _Opts) ->
    {ok, S}.

validate(Msg, Opts) ->
    validate_stage(1, Msg, Opts).

validate_stage(1, Msg, Opts) when is_record(Msg, tx) ->
    validate_stage(1, Msg#tx.data, Opts);
validate_stage(1, #{ <<"Attestations">> := Attestations, <<"Message">> := Content }, Opts) ->
    validate_stage(2, Attestations, Content, Opts);
validate_stage(1, _M, _Opts) -> {false, <<"Required PoDA messages missing">>}.

validate_stage(2, #tx { data = Attestations }, Content, Opts) ->
    validate_stage(2, Attestations, Content, Opts);
validate_stage(2, Attestations, Content, Opts) ->
    ?c({poda_stage, 2}),
    % Ensure that all attestations are valid and signed by a
    % trusted authority.
    case
        lists:all(
            fun({_, Att}) ->
                ?c(validating_attestation),
                ar_bundles:print(Att),
                ar_bundles:verify_item(Att)
            end,
            maps:to_list(Attestations)
        ) of
        true -> validate_stage(3, Content, Attestations, Opts);
        false -> {false, <<"Invalid attestations">>}
    end;

validate_stage(3, Content, Attestations, Opts = #{ quorum := Quorum }) ->
    ?c({poda_stage, 3}),
    Validations =
        lists:filter(
            fun({_, Att}) -> validate_attestation(Content, Att, Opts) end,
            maps:to_list(Attestations)
        ),
    ?c({poda_validations, length(Validations)}),
    case length(Validations) >= Quorum of
        true ->
            ?c({poda_quorum_reached, length(Validations)}),
            true;
        false -> {false, <<"Not enough validations">>}
    end.

validate_attestation(Msg, Att, Opts) ->
    MsgID = ar_util:encode(ar_bundles:id(Msg, unsigned)),
    AttSigner = ar_util:encode(ar_bundles:signer(Att)),
    ?c({poda_attestation, {signer, AttSigner, maps:get(authorities, Opts)}, {msg_id, MsgID}}),
    ar_bundles:print(Att),
    ValidSigner = lists:member(AttSigner, maps:get(authorities, Opts)),
    ?no_prod(use_real_signature_verification),
    ValidSignature = ar_bundles:verify_item(Att),
    RelevantMsg = ar_bundles:id(Att, unsigned) == MsgID orelse
        (lists:keyfind(<<"Attestation-For">>, 1, Att#tx.tags)
            == {<<"Attestation-For">>, MsgID}) orelse
        ar_bundles:member(ar_bundles:id(Msg, unsigned), Att),
    ?c(
        {poda_attestation,
            {valid_signer, ValidSigner},
            {valid_signature, ValidSignature},
            {relevant_msg, RelevantMsg},
            {signer, AttSigner}
        }
    ),
    ValidSigner and ValidSignature and RelevantMsg.

%%% Execution flow: Error handling.
%%% Skip execution of this message, instead returning an error message.
return_error(S = #{ wallet := Wallet }, Reason) ->
    ?c({poda_return_error, Reason}),
    ?debug_wait(10000),
    {skip, S#{
        results => #{
            <<"/Outbox">> =>
                ar_bundles:sign_item(
                    #tx{
                        data = Reason,
                        tags = [{<<"Error">>, <<"PoDA">>}]
                    },
                    Wallet
                )
        }
    }}.

is_user_signed(#tx { data = #{ <<"Message">> := Msg } }) ->
    ?no_prod(use_real_attestation_detection),
    lists:keyfind(<<"From-Process">>, 1, Msg#tx.tags) == false;
is_user_signed(_) -> true.

%%% Attestation flow: Adding attestations to results.

push(_Item, S = #{ results := Results }) ->
    %?c({poda_push, Results}),
    NewRes = attest_to_results(Results, S),
    {ok, S#{ results => NewRes }}.

attest_to_results(Msg, S = #{ wallet := Wallet }) ->
    case is_map(Msg#tx.data) of
        true ->
            % Add attestations to the outbox and spawn items.
            maps:map(
                fun(Key, IndexMsg) ->
                    case lists:member(Key, [<<"/Outbox">>, <<"/Spawn">>]) of
                        true ->
                            ?c({poda_attest_to_results, Key}),
                            maps:map(
                                fun(_, DeepMsg) -> add_attestations(DeepMsg, S) end,
                                IndexMsg#tx.data
                            );
                        false -> IndexMsg
                    end
                end,
                Msg#tx.data
            );
        false -> Msg
    end.

add_attestations(NewMsg, S = #{ assignment := Assignment, store := _Store, logger := _Logger, wallet := Wallet }) ->
    Process = find_process(NewMsg, S),
    case is_record(Process, tx) andalso lists:member({<<"Device">>, <<"PODA">>}, Process#tx.tags) of
        true ->
            #{ authorities := InitAuthorities, quorum := Quorum } =
                extract_opts(Process#tx.tags),
            ?c({poda_push, InitAuthorities, Quorum}),
            % Aggregate validations from other nodes.
            % TODO: Filter out attestations from the current node.
            Attestations = lists:filtermap(
                fun(Address) ->
                    case ao_router:find(compute, ar_bundles:id(Process, unsigned), Address) of
                        {ok, ComputeNode} ->
                            ?c({poda_asking_peer_for_attestation, ComputeNode}),
                            case ao_client:compute(ComputeNode, ar_bundles:id(Process, unsigned), ar_bundles:id(Assignment, unsigned)) of
                                {ok, Att} ->
                                    ?c({poda_got_attestation_from_peer, ComputeNode}),
                                    {true, Att};
                                _ -> false
                            end;
                        _ -> false
                    end
                end,
                InitAuthorities
            ),
            ?c({poda_attestations, length(Attestations)}),
            MsgID = ar_util:encode(ar_bundles:id(NewMsg, unsigned)),
            LocalAttestation = ar_bundles:sign_item(
                #tx{ tags = [{<<"Attestation-For">>, MsgID}], data = <<>> },
                Wallet
            ),
            CompleteAttestations =
                ar_bundles:sign_item(
                    ar_bundles:normalize(
                        #tx {
                            data = 
                                maps:from_list(
                                    lists:zipwith(
                                        fun(Index, Att) -> {integer_to_binary(Index), Att} end,
                                        lists:seq(1, length([LocalAttestation | Attestations])),
                                        [LocalAttestation | Attestations]
                                    )
                                )
                        }
                    ),
                    Wallet
                ),
            ?c(poda_complete_attestations),
            AttestationBundle = ar_bundles:sign_item(
                ar_bundles:normalize(
                    #tx{
                        target = NewMsg#tx.target,
                        data = #{
                            <<"Attestations">> => CompleteAttestations,
                            <<"Message">> => NewMsg
                        }
                    }
                ),
                Wallet
            ),
            ar_bundles:print(AttestationBundle),
            ?c({poda_attestation_bundle_signed, length(Attestations)}),
            AttestationBundle;
        false -> NewMsg
    end.

%% @doc Helper function for parallel execution of attestation
%% gathering.
pfiltermap(Pred, List) ->
    Parent = self(),
    Pids = lists:map(fun(X) -> 
        spawn_monitor(fun() -> 
            Result = {X, Pred(X)},
            ?c({pfiltermap, sending_result, self()}),
            Parent ! {self(), Result}
        end)
    end, List),
    ?c({pfiltermap, waiting_for_results, Pids}),
    [
        Res
    ||
        {true, Res} <-
            lists:map(fun({Pid, Ref}) ->
                receive
                    {Pid, {_Item, Result}} ->
                        ?c({pfiltermap, received_result, Pid}),
                        Result;
                    % Handle crashes as filterable events
                    {'DOWN', Ref, process, Pid, _Reason} ->
                        ?c({pfiltermap, crashed, Pid}),
                        false;
                    Other ->
                        ?c({pfiltermap, unexpected_message, Other}),
                        false
                end
            end, Pids)
    ].

%% @doc Find the process that this message is targeting, in order to
%% determine which attestations to add.
find_process(Item, #{ logger := _Logger, store := Store }) ->
    case Item#tx.target of
        X when X =/= <<>> ->
            ?c({poda_find_process, ar_util:id(Item#tx.target)}),
            ao_cache:read_message(Store, ar_util:id(Item#tx.target));
        _ ->
            case lists:keyfind(<<"Type">>, 1, Item#tx.tags) of
                {<<"Type">>, <<"Process">>} -> Item;
                _ -> process_not_specified
            end
    end.