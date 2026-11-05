--[[

ZAPRET CAP : nfqws1 desync variants that zapret-antidpi.lua does not implement

--lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua --lua-init=@zapret-cap.lua

]]


-- nfqws1 : "--dpi-desync=hostfakesplit --dpi-desync-hostfakesplit-mod=altorder=1"
-- send order : before_host, fake host, after_host, real host. no second fake unlike "hostfakesplit".
-- standard args : direction, payload, fooling, ip_id, rawsend, reconstruct. FOOLING AND REPEATS APPLIED ONLY TO FAKES.
-- arg : host=<str> - hostname template. generate hosts like "random.template". example : e8nzn.vk.com
-- arg : nodrop - do not drop current dissect
function hostfakesplit_alt(ctx, desync)
	if not desync.dis.tcp then
		-- do not cutoff on related icmp
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
			if pos then
				if b_debug then DLOG("hostfakesplit_alt: resolved host range: "..table.concat(zero_based_pos(pos)," ")) end

				-- do not apply fooling to original parts except tcp_ts_up but apply ip_id
				local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
				local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

				local before = string.sub(data,1,pos[1]-1)
				if b_debug then DLOG("hostfakesplit_alt: sending before_host part 0-"..(pos[1]-2).." len="..#before.." : "..hexdump_dlog(before)) end
				if not rawsend_payload_segmented(desync,before,0,opts_orig) then return VERDICT_PASS end

				local fakehost = genhost(pos[2]-pos[1]+1, desync.arg.host)
				if b_debug then DLOG("hostfakesplit_alt: sending fake host part "..(pos[1]-1).."-"..(pos[2]-1).." len="..#fakehost.." : "..hexdump_dlog(fakehost)) end
				if not rawsend_payload_segmented(desync,fakehost,pos[1]-1,opts_fake) then return VERDICT_PASS end

				local after = string.sub(data,pos[2]+1)
				if b_debug then DLOG("hostfakesplit_alt: sending after_host part "..pos[2].."-"..(#data-1).." len="..#after.." : "..hexdump_dlog(after)) end
				if not rawsend_payload_segmented(desync,after,pos[2],opts_orig) then return VERDICT_PASS end

				local host = string.sub(data,pos[1],pos[2])
				if b_debug then DLOG("hostfakesplit_alt: sending real host part "..(pos[1]-1).."-"..(pos[2]-1).." len="..#host.." : "..hexdump_dlog(host)) end
				if not rawsend_payload_segmented(desync,host,pos[1]-1,opts_orig) then return VERDICT_PASS end

				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			else
				DLOG("hostfakesplit_alt: host range cannot be resolved")
			end
		else
			DLOG("hostfakesplit_alt: not acting on further replay pieces")
		end
		-- drop replayed packets if reasm was sent successfully in splitted form
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end
