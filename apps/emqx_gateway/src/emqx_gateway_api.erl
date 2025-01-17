%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
%%
-module(emqx_gateway_api).

-behaviour(minirest_api).

-import(emqx_gateway_http,
        [ return_http_error/2
        ]).

%% minirest behaviour callbacks
-export([api_spec/0]).

%% http handlers
-export([ gateway/2
        , gateway_insta/2
        , gateway_insta_stats/2
        ]).

%%--------------------------------------------------------------------
%% minirest behaviour callbacks
%%--------------------------------------------------------------------

api_spec() ->
    {metadata(apis()), []}.

apis() ->
    [ {"/gateway", gateway}
    , {"/gateway/:name", gateway_insta}
    , {"/gateway/:name/stats", gateway_insta_stats}
    ].
%%--------------------------------------------------------------------
%% http handlers

gateway(get, Request) ->
    Params = maps:get(query_string, Request, #{}),
    Status = case maps:get(<<"status">>, Params, undefined) of
                 undefined -> all;
                 S0 -> binary_to_existing_atom(S0, utf8)
             end,
    {200, emqx_gateway_http:gateways(Status)}.

gateway_insta(delete, #{bindings := #{name := Name0}}) ->
    Name = binary_to_existing_atom(Name0),
    case emqx_gateway:unload(Name) of
        ok ->
            {204};
        {error, not_found} ->
            return_http_error(404, <<"Gateway not found">>)
    end;
gateway_insta(get, #{bindings := #{name := Name0}}) ->
    Name = binary_to_existing_atom(Name0),
    case emqx_gateway:lookup(Name) of
        #{config := _Config} ->
            %% FIXME: Got the parsed config, but we should return rawconfig to
            %% frontend
            RawConf = emqx_config:fill_defaults(
                        emqx_config:get_root_raw([<<"gateway">>])
                       ),
            {200, emqx_map_lib:deep_get([<<"gateway">>, Name0], RawConf)};
        undefined ->
            return_http_error(404, <<"Gateway not found">>)
    end;
gateway_insta(put, #{body := RawConfsIn,
                     bindings := #{name := Name}
                    }) ->
    %% FIXME: Cluster Consistence ??
    case emqx_gateway:update_rawconf(Name, RawConfsIn) of
        ok ->
            {200};
        {error, not_found} ->
            return_http_error(404, <<"Gateway not found">>);
        {error, Reason} ->
            return_http_error(500, Reason)
    end.

gateway_insta_stats(get, _Req) ->
    return_http_error(401, <<"Implement it later (maybe 5.1)">>).


%%--------------------------------------------------------------------
%% Swagger defines
%%--------------------------------------------------------------------

metadata(APIs) ->
    metadata(APIs, []).
metadata([], APIAcc) ->
    lists:reverse(APIAcc);
metadata([{Path, Fun}|More], APIAcc) ->
    Methods = [get, post, put, delete, patch],
    Mds = lists:foldl(fun(M, Acc) ->
              try
                  Acc#{M => swagger(Path, M)}
              catch
                  error : function_clause ->
                      Acc
              end
          end, #{}, Methods),
    metadata(More, [{Path, Mds, Fun} | APIAcc]).

swagger("/gateway", get) ->
    #{ description => <<"Get gateway list">>
     , parameters => params_gateway_status_in_qs()
     , responses =>
        #{ <<"200">> => schema_gateway_overview_list() }
     };
swagger("/gateway/:name", get) ->
    #{ description => <<"Get the gateway configurations">>
     , parameters => params_gateway_name_in_path()
     , responses =>
        #{ <<"404">> => schema_not_found()
         , <<"200">> => schema_gateway_conf()
         }
      };
swagger("/gateway/:name", delete) ->
    #{ description => <<"Delete/Unload the gateway">>
     , parameters => params_gateway_name_in_path()
     , responses =>
        #{ <<"404">> => schema_not_found()
         , <<"204">> => schema_no_content()
         }
      };
swagger("/gateway/:name", put) ->
    #{ description => <<"Update the gateway configurations/status">>
     , parameters => params_gateway_name_in_path()
     , requestBody => schema_gateway_conf()
     , responses =>
        #{ <<"404">> => schema_not_found()
         , <<"200">> => schema_no_content()
         }
     };
swagger("/gateway/:name/stats", get) ->
    #{ description => <<"Get gateway Statistic">>
     , parameters => params_gateway_name_in_path()
     , responses =>
        #{ <<"404">> => schema_not_found()
         , <<"200">> => schema_gateway_stats()
         }
     }.

%%--------------------------------------------------------------------
%% params defines

params_gateway_name_in_path() ->
    [#{ name => name
      , in => path
      , schema => #{type => string}
      , required => true
      }].

params_gateway_status_in_qs() ->
    [#{ name => status
      , in => query
      , schema => #{type => string}
      , required => false
      }].

%%--------------------------------------------------------------------
%% schemas

schema_not_found() ->
    emqx_mgmt_util:error_schema(<<"Gateway not found or unloaded">>).

schema_no_content() ->
    #{description => <<"No Content">>}.

schema_gateway_overview_list() ->
    emqx_mgmt_util:array_schema(
      #{ type => object
       , properties => properties_gateway_overview()
       },
      <<"Gateway Overview list">>
     ).

%% XXX: This is whole confs for all type gateways. It is used to fill the
%% default configurations and generate the swagger-schema
%%
%% NOTE: It is a temporary measure to generate swagger-schema
-define(COAP_GATEWAY_CONFS,
#{<<"authentication">> =>
      #{<<"mechanism">> => <<"password-based">>,
        <<"name">> => <<"authenticator1">>,
        <<"server_type">> => <<"built-in-database">>,
        <<"user_id_type">> => <<"clientid">>},
  <<"enable">> => true,
  <<"enable_stats">> => true,<<"heartbeat">> => <<"30s">>,
  <<"idle_timeout">> => <<"30s">>,
  <<"listeners">> =>
      #{<<"udp">> => #{<<"default">> => #{<<"bind">> => 5683}}},
  <<"mountpoint">> => <<>>,<<"notify_type">> => <<"qos">>,
  <<"publish_qos">> => <<"qos1">>,
  <<"subscribe_qos">> => <<"qos0">>}
).

-define(EXPROTO_GATEWAY_CONFS,
#{<<"enable">> => true,
  <<"enable_stats">> => true,
  <<"handler">> =>
      #{<<"address">> => <<"http://127.0.0.1:9001">>},
  <<"idle_timeout">> => <<"30s">>,
  <<"listeners">> =>
      #{<<"tcp">> =>
            #{<<"default">> =>
                  #{<<"acceptors">> => 8,<<"bind">> => 7993,
                    <<"max_conn_rate">> => 1000,
                    <<"max_connections">> => 10240}}},
  <<"mountpoint">> => <<>>,
  <<"server">> => #{<<"bind">> => 9100}}
).

-define(LWM2M_GATEWAY_CONFS,
#{<<"auto_observe">> => false,
  <<"enable">> => true,
  <<"enable_stats">> => true,
  <<"idle_timeout">> => <<"30s">>,
  <<"lifetime_max">> => <<"86400s">>,
  <<"lifetime_min">> => <<"1s">>,
  <<"listeners">> =>
      #{<<"udp">> => #{<<"default">> => #{<<"bind">> => 5783}}},
  <<"mountpoint">> => <<"lwm2m/%e/">>,
  <<"qmode_time_windonw">> => 22,
  <<"translators">> =>
      #{<<"command">> => <<"dn/#">>,<<"notify">> => <<"up/notify">>,
        <<"register">> => <<"up/resp">>,
        <<"response">> => <<"up/resp">>,
        <<"update">> => <<"up/resp">>},
  <<"update_msg_publish_condition">> =>
      <<"contains_object_list">>,
  <<"xml_dir">> => <<"etc/lwm2m_xml">>}
).

-define(MQTTSN_GATEWAY_CONFS,
#{<<"broadcast">> => true,
  <<"clientinfo_override">> =>
      #{<<"password">> => <<"abc">>,
        <<"username">> => <<"mqtt_sn_user">>},
  <<"enable">> => true,
  <<"enable_qos3">> => true,<<"enable_stats">> => true,
  <<"gateway_id">> => 1,<<"idle_timeout">> => <<"30s">>,
  <<"listeners">> =>
      #{<<"udp">> =>
            #{<<"default">> =>
                  #{<<"bind">> => 1884,<<"max_conn_rate">> => 1000,
                    <<"max_connections">> => 10240000}}},
  <<"mountpoint">> => <<>>,
  <<"predefined">> =>
      [#{<<"id">> => 1,
         <<"topic">> => <<"/predefined/topic/name/hello">>},
       #{<<"id">> => 2,
         <<"topic">> => <<"/predefined/topic/name/nice">>}]}
).

-define(STOMP_GATEWAY_CONFS,
#{<<"authentication">> =>
      #{<<"mechanism">> => <<"password-based">>,
        <<"name">> => <<"authenticator1">>,
        <<"server_type">> => <<"built-in-database">>,
        <<"user_id_type">> => <<"clientid">>},
  <<"clientinfo_override">> =>
      #{<<"password">> => <<"${Packet.headers.passcode}">>,
        <<"username">> => <<"${Packet.headers.login}">>},
  <<"enable">> => true,
  <<"enable_stats">> => true,
  <<"frame">> =>
      #{<<"max_body_length">> => 8192,<<"max_headers">> => 10,
        <<"max_headers_length">> => 1024},
  <<"idle_timeout">> => <<"30s">>,
  <<"listeners">> =>
      #{<<"tcp">> =>
            #{<<"default">> =>
                  #{<<"acceptors">> => 16,<<"active_n">> => 100,
                    <<"bind">> => 61613,<<"max_conn_rate">> => 1000,
                    <<"max_connections">> => 1024000}}},
  <<"mountpoint">> => <<>>}
).

%% --- END

schema_gateway_conf() ->
    emqx_mgmt_util:schema(
      #{oneOf =>
        [ emqx_mgmt_api_configs:gen_schema(?STOMP_GATEWAY_CONFS)
        , emqx_mgmt_api_configs:gen_schema(?MQTTSN_GATEWAY_CONFS)
        , emqx_mgmt_api_configs:gen_schema(?COAP_GATEWAY_CONFS)
        , emqx_mgmt_api_configs:gen_schema(?LWM2M_GATEWAY_CONFS)
        , emqx_mgmt_api_configs:gen_schema(?EXPROTO_GATEWAY_CONFS)
        ]}).

schema_gateway_stats() ->
    emqx_mgmt_util:schema(
      #{ type => object
       , properties =>
        #{ a_key => #{type => string}
       }}).

%%--------------------------------------------------------------------
%% properties

properties_gateway_overview() ->
    ListenerProps =
        [ {name, string,
           <<"Listener Name">>}
        , {status, string,
           <<"Listener Status">>, [<<"activing">>, <<"inactived">>]}
        ],
    emqx_mgmt_util:properties(
      [ {name, string,
         <<"Gateway Name">>}
      , {status, string,
         <<"Gateway Status">>,
         [<<"running">>, <<"stopped">>, <<"unloaded">>]}
      , {started_at, string,
         <<>>}
      , {max_connection, integer, <<>>}
      , {current_connection, integer, <<>>}
      , {listeners, {array, object}, ListenerProps}
      ]).
