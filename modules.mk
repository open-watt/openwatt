# =======================================================================
# OpenWatt -- module registry and resolver
#
# One line per module: key, then requires. A `?` marks a weak require,
# taken only once its own requires are in the set. An umbrella owns no
# code; a removed require drops the umbrella instead of failing.
#
# Selection, from the command line:
#   MODULES   replaces the default set
#   WITH      added to the default set
#   WITHOUT   barred from the set
# `make explain-modules` prints the resolved set and why each module is in.
# =======================================================================

module = $(eval MODULE_KEYS += $(strip $1))$(eval MOD_REQ_$(strip $1) := $(strip $2))
umbrella = $(call module,$1,$2)$(eval MOD_UMBRELLAS += $(strip $1))

$(call module, shell,         )
$(call module, sync,          )
$(call module, profile,       )
$(call module, automation,    )

$(call module, bridge,        )
$(call module, vlan,          )
$(call module, l2_udp,        )
$(call module, rdp,           l2_udp)
$(call module, pcap,          )
$(call module, serial,        )
$(call module, wifi,          )
$(call module, wpan,          )
$(call module, ethernet,      )
$(call module, i2c,           )
$(call module, spi,           )
$(call module, sfp,           i2c)

$(call module, ip_stack,      )
$(call module, inet,          ip_stack)
$(call module, inet6,         inet)
$(call module, udp,           inet)
$(call module, tcp,           inet)
$(call module, ip_forward,    inet)
$(call module, ipv6_ra,       ip_forward inet6)
$(call module, dhcp_client,   udp)
$(call module, dhcp_server,   udp)
$(call module, dns,           udp)
$(call module, ntp,           udp)
$(call module, snmp,          udp)
$(call module, ppp,           inet)
$(call module, telnet,        tcp)
$(call module, tls,           tcp)

$(call module, http_server,   tcp)
$(call module, http_client,   tcp)
$(call module, http_binding,  http_client profile)
$(call module, websocket,     http_server)
$(call module, http_files,    http_server)
$(call module, api,           http_server)
$(call module, ota,           http_server automation)
$(call module, mqtt,          tcp profile)
$(call module, mqtt_broker,   mqtt)
$(call module, esphome,       tcp profile)

$(call module, modbus,        profile)
$(call module, sunspec,       modbus)
$(call module, goodwe,        profile)
$(call module, can,           profile)
$(call module, obd,           can)
$(call module, ezsp,          )
$(call module, cpc,           )
$(call module, spinel,        )
$(call module, zigbee,        ezsp profile)
$(call module, ble,           profile)
$(call module, gpio,          )
$(call module, energy,        profile)
$(call module, tesla_twc,     )
$(call module, tesla_vehicle, ble energy)

$(call umbrella, ip,          inet udp tcp)
$(call umbrella, ipv6,        inet6 udp tcp)
$(call umbrella, dhcp,        dhcp_client dhcp_server)
$(call umbrella, http,        http_server http_client)
$(call umbrella, gateway,     ip_forward dhcp_server ipv6_ra?)
$(call umbrella, l2,          bridge vlan)
$(call umbrella, full,        $(addsuffix ?,$(filter-out $(MOD_UMBRELLAS),$(MODULE_KEYS))))

# mod_resolve(roots, barred) closes over the mod_root sets named in roots into MOD_SET, MOD_WHY_<key> and MOD_ERRORS.

mod_root = $(eval MOD_REQ_@$1 := $3)$(eval MOD_LABEL_@$1 := $2)$(eval MOD_UMBRELLAS += @$1)
mod_hard = $(filter-out %?,$(MOD_REQ_$1))
mod_weak = $(patsubst %?,%,$(filter %?,$(MOD_REQ_$1)))
mod_ready = $(if $(filter-out $(MOD_SET),$(call mod_hard,$1)),,y)
mod_add = $(if $(filter $1,$(MOD_SET)),,$(eval MOD_SET += $1)$(eval MOD_WHY_$1 := $2))
mod_chain = $1$(if $(filter @%,$(MOD_WHY_$1)), ($(MOD_LABEL_$(MOD_WHY_$1))), <- $(call mod_chain,$(MOD_WHY_$1)))
mod_refuse = $(if $(filter $1,$(MOD_UMBRELLAS)),$(eval MOD_DROPPED += $1),$(eval MOD_ERRORS += WITHOUT=$2:~required~by~$(subst $(mod_space),~,$(call mod_chain,$1))))
mod_visit_hard = $(foreach k,$(call mod_hard,$1),$(if $(filter $k,$(MOD_BARRED)),$(call mod_refuse,$1,$k),$(call mod_add,$k,$1)))
mod_visit_weak = $(foreach k,$(call mod_weak,$1),$(if $(filter $k,$(MOD_BARRED) $(MOD_SET)),,$(if $(call mod_ready,$k),$(call mod_add,$k,$1))))
mod_close = $(foreach m,$(filter-out $(MOD_VISITED),$(MOD_SET)),$(eval MOD_VISITED += $m)$(call mod_visit_hard,$m))$(foreach m,$(MOD_SET),$(call mod_visit_weak,$m))$(if $(filter-out $(MOD_VISITED),$(MOD_SET)),$(call mod_close))
mod_near = $(foreach k,$(MODULE_KEYS),$(if $(findstring $1,$k)$(findstring $k,$1),$k))
mod_unknown = $(foreach n,$(patsubst %?,%,$1),$(if $(filter $n,$(MODULE_KEYS)),,$(eval MOD_ERRORS += unknown~module~'$n'$(if $(call mod_near,$n),;~did~you~mean~$(subst $(mod_space),~or~,$(strip $(call mod_near,$n)))?))))
mod_space := $(subst ,, )

mod_resolve = $(strip $(call mod_unknown,$(foreach r,$1,$(MOD_REQ_@$r)) $2)$(eval MOD_BARRED := $2)$(eval MOD_SET := $(addprefix @,$1))$(eval MOD_VISITED :=)$(call mod_close)$(eval MOD_SET := $(sort $(filter-out @% $(MOD_DROPPED),$(MOD_SET)))))
mod_report = $(if $(MOD_ERRORS),$(error module selection failed:$(mod_newline)$(subst ~, ,$(subst $(mod_space),$(mod_newline),$(strip $(MOD_ERRORS))))))

define mod_newline


endef
mod_explain = $(foreach m,$(MOD_SET),$(info $(call mod_chain,$m)))
