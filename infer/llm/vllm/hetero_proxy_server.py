################################################################################
# Copyright(c)2020-2025 Shanghai Biren Technology Co., Ltd. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
import argparse
import asyncio
import copy
import logging
import os
import signal
import socket
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Any

import aiohttp
import msgpack
import zmq
from quart import Quart, make_response, request

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

app = Quart(__name__)


@dataclass
class InstanceDpInfo:
    request_address: str
    handshake_address: str
    dp_rank: int
    dp_size: int
    tp_size: int
    engine_id: str
    rank_infos: list[dict[str, Any]]
    update_time: Any


prefill_instances: dict[str, dict[int, InstanceDpInfo]] = {}
decode_instances: dict[str, dict[int, InstanceDpInfo]] = {}
prefill_dp_count: dict[str, int] = {}
decode_dp_count: dict[str, int] = {}
request_nums = 0


def _cleanup_oldest_instances(instances_dict, type: str, timeout=6):
    current_time = time.time()
    keys_to_delete = set()
    for key, dp_info_dict in instances_dict.items():
        for dp_rank, dp_info in dp_info_dict.items():
            if current_time - dp_info.update_time > timeout:
                keys_to_delete.add(key)
    for key in keys_to_delete:
        del instances_dict[key]
        if type == "prefill":
            prefill_dp_count.pop(key, None)
        elif type == "decode":
            decode_dp_count.pop(key, None)


def _append_whole_dict_unique(target_dict, type: str, data_dict):
    key = data_dict.get("request_address")
    if key is None:
        raise ValueError("data_dict must contain 'request_address' key")

    if key not in target_dict:
        target_dict[key] = {}
    dp_rank = int(data_dict.get("dp_rank", 0))
    dp_info = InstanceDpInfo(
        request_address=data_dict["request_address"],
        handshake_address=data_dict["handshake_address"],
        dp_rank=dp_rank,
        dp_size=int(data_dict.get("dp_size", 1)),
        tp_size=int(data_dict.get("tp_size", 1)),
        engine_id=data_dict.get("engine_id", ""),
        rank_infos=data_dict.get("rank_infos", []),
        update_time=time.time(),
    )
    target_dict[key][dp_rank] = dp_info
    if type == "prefill":
        prefill_dp_count[key] = max(prefill_dp_count.get(key, 0), 0)
    elif type == "decode":
        decode_dp_count[key] = max(decode_dp_count.get(key, 0), 0)
    _cleanup_oldest_instances(target_dict, type=type, timeout=6)
    _instances_ready_cv.notify_all()

    return True


_list_lock = threading.RLock()
_instances_ready_cv = threading.Condition(_list_lock)
_shutdown_event = threading.Event()


def _listen_for_register(hostname, port):
    context = zmq.Context()
    router_socket = context.socket(zmq.ROUTER)
    router_socket.setsockopt(zmq.LINGER, 0)
    router_socket.bind(f"tcp://{hostname}:{port}")
    poller = zmq.Poller()
    poller.register(router_socket, zmq.POLLIN)
    global prefill_instances
    global decode_instances

    try:
        while not _shutdown_event.is_set():
            socks = dict(poller.poll(timeout=1000))
            if router_socket in socks:
                remote_addr, msg = router_socket.recv_multipart()
                data = msgpack.loads(msg)
                if data["type"] == "HELLO":
                    pass
                elif data["type"] == "register" and data["role"] == "P":
                    print(
                        f"###!!!Received registration from prefill instance: {data}"
                    )
                    with _list_lock:
                        _append_whole_dict_unique(
                            prefill_instances, type="prefill", data_dict=data
                        )

                elif data["type"] == "register" and data["role"] == "D":
                    print(
                        f"###!!!Received registration from decode instance: {data}"
                    )
                    with _list_lock:
                        _append_whole_dict_unique(
                            decode_instances, type="decode", data_dict=data
                        )
    finally:
        poller.unregister(router_socket)
        router_socket.close()
        context.term()
        logger.info("ZMQ listener stopped, port %s released", port)


def start_service_discovery(hostname, port):
    if not hostname:
        hostname = socket.gethostname()
    if port == 0:
        raise ValueError("Port cannot be 0")

    _listener_thread = threading.Thread(
        target=_listen_for_register, args=(hostname, port), daemon=True
    )
    _listener_thread.start()
    return _listener_thread


async def send_request_to_prefill(
    endpoint, req_data, request_id, dip, dport, selected_prefill_dp_rank
):
    req_data_copy = req_data

    req_data_copy["kv_transfer_params"].update(
        {
            "do_remote_decode": True,
            "do_remote_prefill": False,
            "remote_block_ids": None,
            "remote_host": dip,
            "remote_port": dport,
        }
    )
    print(
        f"###!!!Sending request to prefill instance at {endpoint} with dp_rank {selected_prefill_dp_rank}, request id: {request_id} \
        and kv_transfer_params {req_data_copy['kv_transfer_params']}"
    )
    req_data_copy["stream"] = False
    req_data_copy["max_tokens"] = 1
    if "max_completion_tokens" in req_data_copy:
        req_data_copy["max_completion_tokens"] = 1
    if "stream_options" in req_data_copy:
        del req_data_copy["stream_options"]
    async with aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=6 * 6000 * 6000)
    ) as session:
        headers = {
            "Authorization": f"Bearer {os.environ.get('OPENAI_API_KEY')}",
            "X-Request-Id": request_id,
        }
        if selected_prefill_dp_rank is not None:
            headers["X-data-parallel-rank"] = str(selected_prefill_dp_rank)
        async with session.post(
            url=endpoint, json=req_data_copy, headers=headers
        ) as response:
            if response.status == 200:
                return await response.json()

            else:
                raise RuntimeError(
                    "send_request_to_prefill response.status != 200response.status = ",
                    response.status,
                )


async def start_decode_request(
    endpoint, req_data, request_id, selected_decode_dp_rank=None
):
    session = aiohttp.ClientSession(
        timeout=aiohttp.ClientTimeout(total=6 * 6000 * 6000)
    )
    print(
        f"###!!!Sending request to decode instance at {endpoint} with dp_rank {selected_decode_dp_rank}, request id: {request_id} \
        and kv_transfer_params {req_data['kv_transfer_params']}"
    )
    headers = {
        "Authorization": f"Bearer {os.environ.get('OPENAI_API_KEY')}",
        "X-Request-Id": request_id,
    }
    if selected_decode_dp_rank is not None:
        headers["X-data-parallel-rank"] = str(selected_decode_dp_rank)
    response = await session.post(url=endpoint, json=req_data, headers=headers)
    return session, response


async def stream_decode_response(session, response, request_id):
    try:
        if response.status == 200:
            async for chunk_bytes in response.content.iter_chunked(1024):
                yield chunk_bytes
        else:
            raise RuntimeError(
                f"decode response.status != 200, status = {response.status}"
            )
    finally:
        await session.close()


def choose_instance(
    request_nums,
    instances_dict: dict[str, dict[int, "InstanceDpInfo"]],
    type: str,
):
    with _instances_ready_cv:
        while len(instances_dict) == 0 and not _shutdown_event.is_set():
            _instances_ready_cv.wait(timeout=1.0)
        if _shutdown_event.is_set():
            raise RuntimeError(
                "Server is shutting down, no instances available"
            )

        keys = list(instances_dict.keys())
        selected_key = keys[request_nums % len(keys)]
        dp_info_dict = instances_dict[selected_key]
        dp_ranks = list(dp_info_dict.keys())
        dp_ranks.sort()

        if type == "prefill":
            host_count = prefill_dp_count.get(selected_key, 1)
            prefill_dp_count[selected_key] = host_count + 1
        elif type == "decode":
            host_count = decode_dp_count.get(selected_key, 1)
            decode_dp_count[selected_key] = host_count + 1
        selected_dp_rank = dp_ranks[host_count % len(dp_ranks)]
        print(
            f"###!!!Selected {type} instance with request_address {selected_key} and dp_rank {selected_dp_rank} for request number {request_nums}"
        )
        return selected_dp_rank, dp_info_dict[selected_dp_rank]


@app.route("/v1/completions", methods=["POST"])
@app.route("/v1/chat/completions", methods=["POST"])
async def handle_request():
    try:
        def _pick_instances():
            global request_nums
            with _list_lock:
                request_nums += 1
                cur_req = request_nums
            print(
                f"###!!!Received request number {cur_req}, current prefill instances: "
                f"{prefill_instances}, current decode instances: {decode_instances}"
            )
            _dp_rank_p, _dp_info_p = choose_instance(
                cur_req, prefill_instances, type="prefill"
            )
            _dp_rank_d, _dp_info_d = choose_instance(
                cur_req, decode_instances, type="decode"
            )
            return _dp_rank_p, _dp_info_p, _dp_rank_d, _dp_info_d

        (
            selected_dp_rank_p,
            dp_info_p,
            selected_dp_rank_d,
            dp_info_d,
        ) = await asyncio.to_thread(_pick_instances)

        def extract_ip_port_fast(address):
            ip_port_list = address.split(":")
            if len(ip_port_list) != 2:
                raise ValueError(f"Invalid address format: {address}")
            return ip_port_list[0], int(ip_port_list[1])

        req_data = await request.get_json()
        request_id = uuid.uuid4().hex

        if not prefill_instances or not decode_instances:
            return await make_response(
                (
                    "Service Unavailable: No prefill or decode instances are registered.",
                    503,
                )
            )

        if dp_info_p is None or dp_info_d is None:
            return await make_response(
                (
                    "Service Unavailable: No prefill or decode instances are registered.",
                    503,
                )
            )

        dip, dport = extract_ip_port_fast(dp_info_d.handshake_address)
        ip, port = extract_ip_port_fast(dp_info_p.handshake_address)

        req_data_to_prefill = copy.deepcopy(req_data)
        req_data_to_prefill["kv_transfer_params"] = {}
        req_data["kv_transfer_params"] = {}
        req_data_to_prefill["kv_transfer_params"]["remote_dp_size"] = (
            dp_info_d.dp_size
        )
        req_data_to_prefill["kv_transfer_params"]["remote_tp_size"] = (
            dp_info_d.tp_size
        )
        req_data_to_prefill["kv_transfer_params"]["remote_engine_id"] = (
            dp_info_d.engine_id
        )
        req_data_to_prefill["kv_transfer_params"]["remote_rank_infos"] = (
            dp_info_d.rank_infos
        )
        print(
            f"###!!!, in handle_request, request_id={request_id},  prefill remote_engine_id={dp_info_d.engine_id}, remote_rank_infos={dp_info_d.rank_infos}",
            flush=True,
        )

        send_prefill_task = asyncio.create_task(
            send_request_to_prefill(
                f"http://{dp_info_p.request_address}{request.path}",
                req_data_to_prefill,
                request_id,
                dip,
                dport,
                selected_dp_rank_p,
            )
        )

        req_data["kv_transfer_params"] = {
            "do_remote_decode": False,
            "do_remote_prefill": True,
            "remote_engine_id": None,
            "remote_block_ids": None,
            "remote_host": ip,
            "remote_port": port,
            "remote_rank_infos": dp_info_p.rank_infos,
        }
        print(
            f"###!!!, in handle_request, request_id={request_id}, decode remote_engine_id={dp_info_p.engine_id}, remote_rank_infos={dp_info_p.rank_infos}",
            flush=True,
        )

        prefill_response = await send_prefill_task
        req_data["kv_transfer_params"]["remote_engine_id"] = prefill_response[
            "kv_transfer_params"
        ]["remote_engine_id"]

        req_data["kv_transfer_params"]["remote_dp_size"] = dp_info_p.dp_size
        req_data["kv_transfer_params"]["remote_tp_size"] = dp_info_p.tp_size

        if selected_dp_rank_p is not None:
            req_data["kv_transfer_params"]["remote_dp_rank"] = (
                selected_dp_rank_p
            )

        decode_request_task = asyncio.create_task(
            start_decode_request(
                f"http://{dp_info_d.request_address}{request.path}",
                req_data,
                request_id,
                selected_dp_rank_d,
            )
        )

        session, decode_response = await decode_request_task
        stream_generator = stream_decode_response(
            session, decode_response, request_id
        )
        response = await make_response(stream_generator)
        return response
    except Exception as e:
        logger.exception("An error occurred while handling the request: %s", e)
        return await make_response(
            (
                f"Internal Server Error: {e!s}",
                500,
            )
        )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Hetero proxy server for PD disaggregated serving"
    )
    parser.add_argument(
        "--host",
        type=str,
        default="0.0.0.0",
        help="Host address to listen on (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=35111,
        help="HTTP port to listen on (default: 35111)",
    )
    parser.add_argument(
        "--zmq-port",
        type=int,
        default=34367,
        help="ZMQ service discovery port (default: 34367)",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    start_service_discovery(args.host, args.zmq_port)
    app.config["BODY_TIMEOUT"] = 360000
    app.config["RESPONSE_TIMEOUT"] = 360000

    async def _serve() -> None:
        loop = asyncio.get_running_loop()

        def _on_shutdown() -> None:
            logger.info("Shutdown signal received, stopping server...")
            _shutdown_event.set()
            with _instances_ready_cv:
                _instances_ready_cv.notify_all()

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, _on_shutdown)
            except (NotImplementedError, OSError):
                signal.signal(sig, lambda s, f: _on_shutdown())

        await app.run_task(host=args.host, port=args.port)

    asyncio.run(_serve())
