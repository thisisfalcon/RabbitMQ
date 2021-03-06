%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_channel_sup).

-behaviour(supervisor2).

-export([start_link/1]).

-export([init/1]).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([start_link_args/0]).

-type(start_link_args() ::
        {'tcp', rabbit_net:socket(), rabbit_channel:channel_number(),
         non_neg_integer(), pid(), string(), rabbit_types:protocol(),
         rabbit_types:user(), rabbit_types:vhost(), rabbit_framing:amqp_table(),
         pid()} |
        {'direct', rabbit_channel:channel_number(), pid(), string(),
         rabbit_types:protocol(), rabbit_types:user(), rabbit_types:vhost(),
         rabbit_framing:amqp_table(), pid()}).

-spec(start_link/1 :: (start_link_args()) -> {'ok', pid(), {pid(), any()}}).

-endif.

%%----------------------------------------------------------------------------
%% rabbit_channel_sup监督进程的启动，然后在rabbit_channel_sup监督进程下启动rabbit_limiter进程，rabbit_writer进程，rabbit_channel进程
start_link({tcp, Sock, Channel, FrameMax, ReaderPid, ConnName, Protocol, User,
			VHost, Capabilities, Collector}) ->
	%% 先启动rabbit_channel_sup监督进程，然后在rabbit_channel_sup监督进程下启动rabbit_writer进程和rabbit_limiter进程
	{ok, SupPid} = supervisor2:start_link(
					 ?MODULE, {tcp, Sock, Channel, FrameMax,
							   ReaderPid, Protocol, {ConnName, Channel}}),
	%% 从rabbit_channel_sup监督进程中取得rabbit_limiter进程的Pid
	[LimiterPid] = supervisor2:find_child(SupPid, limiter),
	%% 从rabbit_channel_sup监督进程中取得rabbit_writer进程的Pid
	[WriterPid] = supervisor2:find_child(SupPid, writer),
	%% rabbit_channel_sup监督进程下启动rabbit_channel进程
	{ok, ChannelPid} =
		supervisor2:start_child(
		  SupPid,
		  {channel, {rabbit_channel, start_link,
					 [Channel, ReaderPid, WriterPid, ReaderPid, ConnName,
					  Protocol, User, VHost, Capabilities, Collector,
					  LimiterPid]},
		   intrinsic, ?MAX_WAIT, worker, [rabbit_channel]}),
	{ok, AState} = rabbit_command_assembler:init(Protocol),
	{ok, SupPid, {ChannelPid, AState}};


start_link({direct, Channel, ClientChannelPid, ConnPid, ConnName, Protocol,
			User, VHost, Capabilities, Collector}) ->
	{ok, SupPid} = supervisor2:start_link(
					 ?MODULE, {direct, {ConnName, Channel}}),
	[LimiterPid] = supervisor2:find_child(SupPid, limiter),
	{ok, ChannelPid} =
		supervisor2:start_child(
		  SupPid,
		  {channel, {rabbit_channel, start_link,
					 [Channel, ClientChannelPid, ClientChannelPid, ConnPid,
					  ConnName, Protocol, User, VHost, Capabilities, Collector,
					  LimiterPid]},
		   intrinsic, ?MAX_WAIT, worker, [rabbit_channel]}),
	{ok, SupPid, {ChannelPid, none}}.

%%----------------------------------------------------------------------------

init(Type) ->
	{ok, {{one_for_all, 0, 1}, child_specs(Type)}}.


%% 启动rabbit_writer进程
child_specs({tcp, Sock, Channel, FrameMax, ReaderPid, Protocol, Identity}) ->
	[{writer, {rabbit_writer, start_link,
			   [Sock, Channel, FrameMax, Protocol, ReaderPid, Identity, true]},
	  intrinsic, ?MAX_WAIT, worker, [rabbit_writer]}
		 | child_specs({direct, Identity})];


%% 启动rabbit_limiter进程
child_specs({direct, Identity}) ->
	[{limiter, {rabbit_limiter, start_link, [Identity]},
	  transient, ?MAX_WAIT, worker, [rabbit_limiter]}].
