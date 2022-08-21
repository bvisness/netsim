package main

import "core:container/queue"
import "core:encoding/json"
import "core:fmt"
import "core:intrinsics"

load_config :: proc(config: string, nodes: ^[dynamic]Node, conns: ^[dynamic]Connection) -> bool {
	blah, err := json.parse(transmute([]u8)config, json.DEFAULT_SPECIFICATION, true)
	if err != nil {
		fmt.printf("%s\n", err)
		return false
	}
	obj_map := blah.(json.Object) or_return

	// parse nodes
	nodes_obj := obj_map["nodes"].(json.Array) or_return
	for v in nodes_obj {
		obj := v.(json.Object) or_return

		name := obj["name"].(string) or_return

		pos_map := obj["pos"].(json.Object) or_return

		x := pos_map["x"].(i64) or_return
		y := pos_map["y"].(i64) or_return
		pos := Vec2{f32(x), f32(y)}

		interfaces := make([dynamic]Interface)
		interfaces_arr := obj["interfaces"].(json.Array) or_return
		for interface in interfaces_arr {
			ip_str := interface.(string) or_return
			ip := str_to_ip(ip_str) or_return

			append(&interfaces, Interface{ip = ip})
		}

		rules := make([dynamic]RoutingRule)
		rules_arr := obj["rules"].(json.Array) or_return
		for rule_obj in rules_arr {
			rule := rule_obj.(json.Object) or_return

			ip_str := rule["ip"].(string) or_return
			ip := str_to_ip(ip_str) or_return

			subnet_str := rule["subnet"].(string) or_return
			subnet_mask := str_to_ip(subnet_str) or_return

			interface := rule["interface"].(i64) or_return

			append(&rules, RoutingRule{ip = ip, subnet_mask = subnet_mask, interface_id = int(interface)})
		}

		packets_per_tick, ok := obj["packets_per_tick"].(i64)
		if !ok {
			packets_per_tick = 1
		}
		max_buffer_size, ok2 := obj["buffer_size"].(i64)
		if !ok2 {
			max_buffer_size = 15
		}

		append(nodes, make_node(pos, name, interfaces[:], rules, int(packets_per_tick), int(max_buffer_size)))
	}

	// parse connections
	conns_obj := obj_map["conns"].(json.Array) or_return
	for v in conns_obj {
		obj := v.(json.Object) or_return

		src_map := obj["src"].(json.Object) or_return
		src_node_id := src_map["node_id"].(i64) or_return
		src_interface_id := src_map["interface_id"].(i64) or_return

		dst_map := obj["dst"].(json.Object) or_return
		dst_node_id := dst_map["node_id"].(i64) or_return
		dst_interface_id := dst_map["interface_id"].(i64) or_return

		loss_factor, ok := obj["loss_factor"].(f64)
		if !ok {
			loss_factor = 0
		}

		append(conns, Connection{
			src_id = ConnectionID{node_id = int(src_node_id), interface_id = int(src_interface_id)},
			dst_id = ConnectionID{node_id = int(dst_node_id), interface_id = int(dst_interface_id)},
			loss_factor = f32(loss_factor),
		})
	}

	return true
}

net_config := `
{
	"nodes": [
		{
			"name": "me",
			"pos": { "x": 0, "y": 400 },
			"interfaces": [ "2.2.2.123" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 }
			]
		},
		{
			"name": "comcast",
			"pos": { "x": 200, "y": 400 },
			"interfaces": [ "2.2.2.1", "2.2.2.2", "2.2.2.3" ],
			"rules": [
				{ "ip": "2.2.2.123", "subnet": "255.255.255.255", "interface": 0 },
				{ "ip": "3.0.0.0",   "subnet": "255.0.0.0",       "interface": 1 },
				{ "ip": "4.0.0.0",   "subnet": "255.0.0.0",       "interface": 2 },
				{ "ip": "5.0.0.0",   "subnet": "255.0.0.0",       "interface": 2 }
			],
			"packets_per_tick": 1
		},
		{
			"name": "google",
			"pos": { "x": 400, "y": 200 },
			"interfaces": [ "3.3.3.1", "3.3.3.2" ],
			"rules": [
				{ "ip": "2.0.0.0", "subnet": "255.0.0.0", "interface": 0 },
				{ "ip": "4.0.0.0", "subnet": "255.0.0.0", "interface": 1 },
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0",   "interface": 1 }
			],
			"packets_per_tick": 1
		},
		{
			"name": "cloudflare",
			"pos": { "x": 400, "y": 600 },
			"interfaces": [ "4.4.4.1", "4.4.4.2", "4.4.4.3" ],
			"rules": [
				{ "ip": "2.0.0.0", "subnet": "255.0.0.0", "interface": 0 },
				{ "ip": "3.0.0.0", "subnet": "255.0.0.0", "interface": 1 },
				{ "ip": "5.0.0.0", "subnet": "255.0.0.0", "interface": 2 }
			],
			"packets_per_tick": 1
		},
		{
			"name": "discord_hub",
			"pos": { "x": 600, "y": 600 },
			"interfaces": [ "5.5.5.1", "5.5.5.2", "5.5.5.2", "5.5.5.2" ],
			"rules": [
				{ "ip": "4.0.0.0",   "subnet": "255.0.0.0",       "interface": 0 },
				{ "ip": "5.5.100.1", "subnet": "255.255.255.255", "interface": 1 },
				{ "ip": "5.5.100.2", "subnet": "255.255.255.255", "interface": 2 },
				{ "ip": "5.5.100.3", "subnet": "255.255.255.255", "interface": 3 },
				{ "ip": "0.0.0.0",   "subnet": "0.0.0.0",         "interface": 0 },
			],
			"packets_per_tick": 1
		},
		{
			"name": "discord_1",
			"pos": { "x": 750, "y": 475 },
			"interfaces": [ "5.5.100.1" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		},
		{
			"name": "discord_2",
			"pos": { "x": 750, "y": 600 },
			"interfaces": [ "5.5.100.2" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		},
		{
			"name": "discord_3",
			"pos": { "x": 750, "y": 725 },
			"interfaces": [ "5.5.100.3" ],
			"rules": [
				{ "ip": "0.0.0.0", "subnet": "0.0.0.0", "interface": 0 },
			]
		}
	],
	"conns": [
		{
			"name": "me_comcast",
			"src": { "node_id": 0, "interface_id": 0 },
			"dst": { "node_id": 1, "interface_id": 0 }
		},
		{
			"name": "comcast_google",
			"src": { "node_id": 1, "interface_id": 1 },
			"dst": { "node_id": 2, "interface_id": 0 }
		},
		{
			"name": "comcast_cloudflare",
			"src": { "node_id": 1, "interface_id": 2 },
			"dst": { "node_id": 3, "interface_id": 0 },
			"loss_factor": 0
		},
		{
			"name": "google_cloudflare",
			"src": { "node_id": 2, "interface_id": 1 },
			"dst": { "node_id": 3, "interface_id": 1 }
		},
		{
			"name": "cloudflare_discord_hub",
			"src": { "node_id": 3, "interface_id": 2 },
			"dst": { "node_id": 4, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_1",
			"src": { "node_id": 4, "interface_id": 1 },
			"dst": { "node_id": 5, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_2",
			"src": { "node_id": 4, "interface_id": 2 },
			"dst": { "node_id": 6, "interface_id": 0 }
		},
		{
			"name": "discord_hub_discord_3",
			"src": { "node_id": 4, "interface_id": 3 },
			"dst": { "node_id": 7, "interface_id": 0 }
		}
	]
}
`
