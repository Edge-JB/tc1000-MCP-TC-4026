using System;
using System.Collections.Generic;
using System.Globalization;
using System.Xml;

namespace Te1000Daemon
{
    // Ported from te1000-bridge.ps1 (L7924-8520): mapping-info produce/consume/clear,
    // ADS route list/search/add, silent-mode + target-platform get/set, solution/PLC
    // archive save, independent-file (SaveInOwnFile) get/set, and node Disabled get/set.
    //
    // Route object: the PS bridge does NOT use a separate AmsRouter / COM router. All
    // route operations go through the SYSTEM tree item 'TIRR' (the "Routes" node) on
    // the cached $sysManager, driven via ProduceXml/ConsumeXml envelopes
    // (<TreeItem><RoutePrj>...). list_routes parses the produced XML; broadcast/host
    // search triggers via ConsumeXml then re-reads ProduceXml after a sleep; add_route
    // / add_project_route apply an <AddRoute>/<AddProjectRoute> ConsumeXml (mirrors PS
    // Set-TreeItemXml == ComHelpers.ConsumeXml, which surfaces GetLastXmlError).
    internal static class MappingRouteActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_produce_mapping_info"] = ProduceMappingInfo;
            h["twincat_consume_mapping_info"] = ConsumeMappingInfo;
            h["twincat_clear_mapping_info"] = ClearMappingInfo;
            h["twincat_list_routes"] = ListRoutes;
            h["twincat_route_broadcast_search"] = RouteBroadcastSearch;
            h["twincat_route_search_host"] = RouteSearchHost;
            h["twincat_add_route"] = AddRoute;
            h["twincat_add_project_route"] = AddProjectRoute;
            h["twincat_get_silent_mode"] = GetSilentMode;
            h["twincat_set_silent_mode"] = SetSilentMode;
            h["twincat_get_target_platform"] = GetTargetPlatform;
            h["twincat_set_target_platform"] = SetTargetPlatform;
            h["twincat_save_solution_archive"] = SaveSolutionArchive;
            h["twincat_save_plc_archive"] = SavePlcArchive;
            h["twincat_get_independent_file"] = GetIndependentFile;
            h["twincat_set_independent_file"] = SetIndependentFile;
            h["twincat_get_node_disabled"] = GetNodeDisabled;
            h["twincat_set_node_disabled"] = SetNodeDisabled;
        }

        // ---- helpers ---------------------------------------------------------

        // Get-AutomationSettings (bridge L695-703): retry TcAutomationSettings.
        private static dynamic GetAutomationSettings(dynamic dte)
        {
            return ComHelpers.WithRetry<dynamic>(delegate()
            {
                dynamic settings = dte.GetObject("TcAutomationSettings");
                if (settings == null) throw new BridgeException("TcAutomationSettings is null");
                return settings;
            }, 20, 250);
        }

        // PowerShell [xml] $n.Name resolves to a child element's text OR an attribute
        // of the same name. Mirror that flexibility: prefer a child element, fall back
        // to an attribute. Returns null when neither is present (Get-SafeValue -> null).
        private static string XmlField(XmlNode node, string name)
        {
            if (node == null) return null;
            XmlElement el = node as XmlElement;
            if (el != null)
            {
                XmlNode child = el.SelectSingleNode(name);
                if (child != null) return child.InnerText;
                XmlAttribute attr = el.Attributes[name];
                if (attr != null) return attr.Value;
            }
            return null;
        }

        // ---- mapping info ----------------------------------------------------

        // twincat_produce_mapping_info (L7924-7945): read-only; serialize all links.
        private static Json.JObj ProduceMappingInfo(ActionContext ctx)
        {
            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            string xml;
            try { xml = (string)sysManager.ProduceMappingInfo(); }
            catch (Exception ex)
            {
                throw new BridgeException("ProduceMappingInfo failed: " + ex.Message + " (" + ComHelpers.ErrorCode(ex) + ")");
            }

            var data = new Json.JObj();
            data["xml"] = xml == null ? "" : xml;
            return data;
        }

        // twincat_consume_mapping_info (L7947-7979): re-apply mapping XML (MUTATES).
        private static Json.JObj ConsumeMappingInfo(ActionContext ctx)
        {
            string xml = ctx.Payload.Str("xml");
            if (string.IsNullOrWhiteSpace(xml)) throw new BridgeException("xml is required");

            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic dte = ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            try { sysManager.ConsumeMappingInfo(xml); }
            catch (Exception ex)
            {
                throw new BridgeException("ConsumeMappingInfo failed: " + ex.Message + " (" + ComHelpers.ErrorCode(ex) + ")");
            }

            if (save) dte.ExecuteCommand("File.SaveAll");

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["consumed"] = true;
            data["saved"] = save;
            return data;
        }

        // twincat_clear_mapping_info (L7981-8008): remove ALL links (MUTATES).
        // ALLOW_TWINCAT_DELETE is enforced in index.js; the PS handler does not re-check.
        private static Json.JObj ClearMappingInfo(ActionContext ctx)
        {
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic dte = ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            try { sysManager.ClearMappingInfo(); }
            catch (Exception ex)
            {
                throw new BridgeException("ClearMappingInfo failed: " + ex.Message + " (" + ComHelpers.ErrorCode(ex) + ")");
            }

            if (save) dte.ExecuteCommand("File.SaveAll");

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["cleared"] = true;
            data["saved"] = save;
            return data;
        }

        // ---- routes ----------------------------------------------------------

        // twincat_list_routes (L8010-8046): parse 'TIRR' ProduceXml RemoteConnections.
        private static Json.JObj ListRoutes(ActionContext ctx)
        {
            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, "TIRR");

            var routes = new Json.JArr();
            string xml = ComHelpers.SafeStr(delegate() { return item.ProduceXml(); });
            if (!string.IsNullOrEmpty(xml))
            {
                try
                {
                    var doc = new XmlDocument();
                    doc.LoadXml(xml);
                    XmlNodeList nodes = doc.SelectNodes("//TreeItem/RoutePrj/RemoteConnections/*");
                    if (nodes != null)
                    {
                        foreach (XmlNode n in nodes)
                        {
                            string rName = XmlField(n, "Name");
                            string rNetId = XmlField(n, "NetId");
                            if (string.IsNullOrWhiteSpace(rNetId)) rNetId = XmlField(n, "AmsNetId");
                            string rAddr = XmlField(n, "Address");
                            if (string.IsNullOrWhiteSpace(rAddr)) rAddr = XmlField(n, "IpAddr");

                            var entry = new Json.JObj();
                            entry["name"] = rName;
                            entry["netId"] = rNetId;
                            entry["address"] = rAddr;
                            entry["type"] = n.LocalName;
                            routes.Add(entry);
                        }
                    }
                }
                catch
                {
                    routes = new Json.JArr();
                }
            }

            var data = new Json.JObj();
            data["count"] = routes.Count;
            data["routes"] = routes;
            return data;
        }

        // twincat_route_broadcast_search (L8048-8089): trigger broadcast search via
        // ConsumeXml, sleep, re-read ProduceXml for TargetList/Target.
        private static Json.JObj RouteBroadcastSearch(ActionContext ctx)
        {
            int timeoutMs = ctx.Payload.Truthy("timeoutMs") ? ctx.Payload.Int("timeoutMs") : 4000;

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, "TIRR");

            string trigger = "<TreeItem><RoutePrj><TargetList><BroadcastSearch>true</BroadcastSearch></TargetList></RoutePrj></TreeItem>";
            try { item.ConsumeXml(trigger); }
            catch (Exception ex)
            {
                string e = ComHelpers.SafeStr(delegate() { return item.GetLastXmlError(); });
                if (!string.IsNullOrEmpty(e)) throw new BridgeException("ConsumeXml failed: " + e);
                throw new BridgeException(ex.Message);
            }
            System.Threading.Thread.Sleep(timeoutMs);

            var targets = new Json.JArr();
            string res = ComHelpers.SafeStr(delegate() { return item.ProduceXml(); });
            if (!string.IsNullOrEmpty(res))
            {
                try
                {
                    var doc = new XmlDocument();
                    doc.LoadXml(res);
                    XmlNodeList nodes = doc.SelectNodes("//TreeItem/RoutePrj/TargetList/Target");
                    if (nodes != null)
                    {
                        foreach (XmlNode t in nodes)
                        {
                            var entry = new Json.JObj();
                            entry["name"] = XmlField(t, "Name");
                            entry["netId"] = XmlField(t, "NetId");
                            entry["ipAddr"] = XmlField(t, "IpAddr");
                            targets.Add(entry);
                        }
                    }
                }
                catch
                {
                    targets = new Json.JArr();
                }
            }

            var data = new Json.JObj();
            data["count"] = targets.Count;
            data["targets"] = targets;
            return data;
        }

        // twincat_route_search_host (L8091-8144): targeted host search; first Target.
        private static Json.JObj RouteSearchHost(ActionContext ctx)
        {
            string searchHost = ctx.Payload.Str("host");
            if (string.IsNullOrWhiteSpace(searchHost)) throw new BridgeException("host is required");
            int timeoutMs = ctx.Payload.Truthy("timeoutMs") ? ctx.Payload.Int("timeoutMs") : 4000;

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, "TIRR");

            string hx = PathUtil.XmlEscape(searchHost);
            string trigger = "<TreeItem><RoutePrj><TargetList><Search>" + hx + "</Search></TargetList></RoutePrj></TreeItem>";
            try { item.ConsumeXml(trigger); }
            catch (Exception ex)
            {
                string e = ComHelpers.SafeStr(delegate() { return item.GetLastXmlError(); });
                if (!string.IsNullOrEmpty(e)) throw new BridgeException("ConsumeXml failed: " + e);
                throw new BridgeException(ex.Message);
            }
            System.Threading.Thread.Sleep(timeoutMs);

            Json.JObj target = null;
            bool found = false;
            string res = ComHelpers.SafeStr(delegate() { return item.ProduceXml(); });
            if (!string.IsNullOrEmpty(res))
            {
                try
                {
                    var doc = new XmlDocument();
                    doc.LoadXml(res);
                    XmlNode t = doc.SelectSingleNode("//TreeItem/RoutePrj/TargetList/Target");
                    if (t != null)
                    {
                        target = new Json.JObj();
                        target["name"] = XmlField(t, "Name");
                        target["netId"] = XmlField(t, "NetId");
                        target["ipAddr"] = XmlField(t, "IpAddr");
                        target["version"] = XmlField(t, "Version");
                        target["os"] = XmlField(t, "OS");
                        found = true;
                    }
                }
                catch
                {
                    target = null;
                    found = false;
                }
            }

            var data = new Json.JObj();
            data["host"] = searchHost;
            data["found"] = found;
            data["target"] = target;
            return data;
        }

        // twincat_add_route (L8146-8196): write an ADS route via AddRoute envelope.
        // The PS handler ITSELF re-checks confirm=ALLOW_TWINCAT_ROUTE_WRITE, so keep it.
        private static Json.JObj AddRoute(ActionContext ctx)
        {
            if (!string.Equals(ctx.Payload.Str("confirm"), "ALLOW_TWINCAT_ROUTE_WRITE", StringComparison.Ordinal))
            {
                throw new BridgeException("Blocked: confirm=ALLOW_TWINCAT_ROUTE_WRITE required to write an ADS route.");
            }
            string remoteName = ctx.Payload.Str("remoteName");
            string remoteNetId = ctx.Payload.Str("remoteNetId");
            string remoteIpAddr = ctx.Payload.Str("remoteIpAddr");
            string remoteHostName = ctx.Payload.Str("remoteHostName");
            if (string.IsNullOrWhiteSpace(remoteName)) throw new BridgeException("remoteName is required");
            if (string.IsNullOrWhiteSpace(remoteNetId)) throw new BridgeException("remoteNetId is required");
            if (string.IsNullOrWhiteSpace(remoteIpAddr) && string.IsNullOrWhiteSpace(remoteHostName))
            {
                throw new BridgeException("one of remoteIpAddr / remoteHostName is required");
            }

            string sb = "<AddRoute>";
            sb += "<RemoteName>" + PathUtil.XmlEscape(remoteName) + "</RemoteName>";
            sb += "<RemoteNetId>" + PathUtil.XmlEscape(remoteNetId) + "</RemoteNetId>";
            if (!string.IsNullOrWhiteSpace(remoteIpAddr))
            {
                sb += "<RemoteIpAddr>" + PathUtil.XmlEscape(remoteIpAddr) + "</RemoteIpAddr>";
            }
            else if (!string.IsNullOrWhiteSpace(remoteHostName))
            {
                sb += "<RemoteHostName>" + PathUtil.XmlEscape(remoteHostName) + "</RemoteHostName>";
            }
            string userName = ctx.Payload.Str("userName");
            if (!string.IsNullOrWhiteSpace(userName))
            {
                sb += "<UserName>" + PathUtil.XmlEscape(userName) + "</UserName>";
            }
            string password = ctx.Payload.Str("password");
            if (!string.IsNullOrWhiteSpace(password))
            {
                sb += "<Password>" + PathUtil.XmlEscape(password) + "</Password>";
            }
            if (ctx.Payload.Has("noEncryption") && ctx.Payload.Bool("noEncryption"))
            {
                sb += "<NoEncryption>1</NoEncryption>";
            }
            string localName = ctx.Payload.Str("localName");
            if (!string.IsNullOrWhiteSpace(localName))
            {
                sb += "<LocalName>" + PathUtil.XmlEscape(localName) + "</LocalName>";
            }
            sb += "</AddRoute>";
            string xml = "<TreeItem><RoutePrj><RemoteConnections>" + sb + "</RemoteConnections></RoutePrj></TreeItem>";

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sysManager, "TIRR");
            ComHelpers.ConsumeXml(item, xml);

            var data = new Json.JObj();
            data["added"] = true;
            data["remoteName"] = remoteName;
            data["remoteNetId"] = remoteNetId;
            return data;
        }

        // twincat_add_project_route (L8198-8236): AddProjectRoute envelope.
        private static Json.JObj AddProjectRoute(ActionContext ctx)
        {
            if (!string.Equals(ctx.Payload.Str("confirm"), "ALLOW_TWINCAT_ROUTE_WRITE", StringComparison.Ordinal))
            {
                throw new BridgeException("Blocked: confirm=ALLOW_TWINCAT_ROUTE_WRITE required to write an ADS route.");
            }
            string rName = ctx.Payload.Str("name");
            string rNetId = ctx.Payload.Str("netId");
            string rIpAddr = ctx.Payload.Str("ipAddr");
            string rHostName = ctx.Payload.Str("hostName");
            if (string.IsNullOrWhiteSpace(rName)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(rNetId)) throw new BridgeException("netId is required");
            if (string.IsNullOrWhiteSpace(rIpAddr) && string.IsNullOrWhiteSpace(rHostName))
            {
                throw new BridgeException("one of ipAddr / hostName is required");
            }

            string sb = "<AddProjectRoute>";
            sb += "<Name>" + PathUtil.XmlEscape(rName) + "</Name>";
            sb += "<NetId>" + PathUtil.XmlEscape(rNetId) + "</NetId>";
            if (!string.IsNullOrWhiteSpace(rIpAddr))
            {
                sb += "<IpAddr>" + PathUtil.XmlEscape(rIpAddr) + "</IpAddr>";
            }
            else if (!string.IsNullOrWhiteSpace(rHostName))
            {
                sb += "<HostName>" + PathUtil.XmlEscape(rHostName) + "</HostName>";
            }
            sb += "</AddProjectRoute>";
            string xml = "<TreeItem><RoutePrj><RemoteConnections>" + sb + "</RemoteConnections></RoutePrj></TreeItem>";

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sysManager, "TIRR");
            ComHelpers.ConsumeXml(item, xml);

            var data = new Json.JObj();
            data["added"] = true;
            data["name"] = rName;
            data["netId"] = rNetId;
            return data;
        }

        // ---- silent mode -----------------------------------------------------

        // twincat_get_silent_mode (L8238-8250).
        private static Json.JObj GetSilentMode(ActionContext ctx)
        {
            dynamic dte = ctx.Dte(true);
            dynamic settings = GetAutomationSettings(dte);
            bool silent = false;
            try { silent = (bool)settings.SilentMode; } catch { silent = false; }

            var data = new Json.JObj();
            data["silentMode"] = silent;
            return data;
        }

        // twincat_set_silent_mode (L8252-8271): config-level mutation.
        private static Json.JObj SetSilentMode(ActionContext ctx)
        {
            if (!ctx.Payload.Has("enabled")) throw new BridgeException("'enabled' is required (boolean)");
            bool enabled = ctx.Payload.Bool("enabled");

            dynamic dte = ctx.Dte(true);
            dynamic settings = GetAutomationSettings(dte);
            bool prev = (bool)settings.SilentMode;
            settings.SilentMode = enabled;

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["silentMode"] = enabled;
            data["previous"] = prev;
            return data;
        }

        // ---- target platform -------------------------------------------------

        // twincat_get_target_platform (L8273-8292). The PS typed-helper fallback
        // ([Te1000SettingsHelper]::GetActiveTargetPlatform) is not available in the
        // daemon; if late-bound ConfigurationManager.ActiveTargetPlatform throws we
        // surface that error (see report note).
        private static Json.JObj GetTargetPlatform(ActionContext ctx)
        {
            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            string platform;
            try
            {
                dynamic cfg = sysManager.ConfigurationManager;
                platform = (string)cfg.ActiveTargetPlatform;
            }
            catch (Exception ex)
            {
                throw new BridgeException("ActiveTargetPlatform is not accessible (late-bound) and the typed settings helper is unavailable in the daemon: " + ex.Message);
            }

            var data = new Json.JObj();
            data["activeTargetPlatform"] = platform;
            return data;
        }

        // twincat_set_target_platform (L8294-8322): config-level mutation.
        private static Json.JObj SetTargetPlatform(ActionContext ctx)
        {
            string platform = ctx.Payload.Str("platform");
            string[] allowed = new string[] { "TwinCAT RT (x86)", "TwinCAT RT (x64)" };
            bool ok = false;
            for (int i = 0; i < allowed.Length; i++) { if (allowed[i] == platform) { ok = true; break; } }
            if (!ok)
            {
                throw new BridgeException("platform must be exactly one of: '" + string.Join("', '", allowed) + "'");
            }

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            string prev;
            try
            {
                dynamic cfg = sysManager.ConfigurationManager;
                prev = (string)cfg.ActiveTargetPlatform;
                cfg.ActiveTargetPlatform = platform;
            }
            catch (Exception ex)
            {
                throw new BridgeException("ActiveTargetPlatform is not accessible (late-bound) and the typed settings helper is unavailable in the daemon: " + ex.Message);
            }

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["activeTargetPlatform"] = platform;
            data["previous"] = prev;
            return data;
        }

        // ---- archives --------------------------------------------------------

        // twincat_save_solution_archive (L8324-8353): SysManager.SaveAsArchive(.tszip).
        // PS typed-helper fallback unavailable -> surface the COM error if it throws.
        private static Json.JObj SaveSolutionArchive(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required (absolute path ending in .tszip)");
            if (!file.ToLowerInvariant().EndsWith(".tszip")) throw new BridgeException("file must end in .tszip: " + file);
            string parent = System.IO.Path.GetDirectoryName(file);
            if (string.IsNullOrWhiteSpace(parent) || !System.IO.Directory.Exists(parent))
            {
                throw new BridgeException("parent directory does not exist (not created automatically): " + parent);
            }

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            try { sysManager.SaveAsArchive(file); }
            catch (Exception ex)
            {
                throw new BridgeException("SaveAsArchive failed (late-bound) and the typed settings helper is unavailable in the daemon: " + ex.Message);
            }

            var data = new Json.JObj();
            data["file"] = file;
            data["saved"] = true;
            return data;
        }

        // twincat_save_plc_archive (L8356-8392): TIPC.ExportChild(name, .tpzip).
        private static Json.JObj SavePlcArchive(ActionContext ctx)
        {
            string file = ctx.Payload.Str("file");
            if (string.IsNullOrWhiteSpace(file)) throw new BridgeException("file is required (absolute path ending in .tpzip)");
            if (!file.ToLowerInvariant().EndsWith(".tpzip")) throw new BridgeException("file must end in .tpzip: " + file);
            string parent = System.IO.Path.GetDirectoryName(file);
            if (string.IsNullOrWhiteSpace(parent) || !System.IO.Directory.Exists(parent))
            {
                throw new BridgeException("parent directory does not exist (not created automatically): " + parent);
            }

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic plc = ComHelpers.GetTreeItem(sysManager, "TIPC");

            string childName = ctx.Payload.Truthy("name") ? ctx.Payload.Str("name") : null;
            if (string.IsNullOrWhiteSpace(childName))
            {
                if (ComHelpers.ChildCount(plc) < 1) throw new BridgeException("No PLC project found under TIPC");
                childName = (string)plc.Child(1).Name;
            }

            plc.ExportChild(childName, file);

            var data = new Json.JObj();
            data["parentPath"] = "TIPC";
            data["childName"] = childName;
            data["file"] = file;
            data["saved"] = true;
            return data;
        }

        // ---- independent file (SaveInOwnFile) --------------------------------

        // twincat_get_independent_file (L8395-8421).
        private static Json.JObj GetIndependentFile(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, path);

            bool got;
            bool value = SafeBool(delegate() { return (bool)item.SaveInOwnFile; }, out got);
            if (!got)
            {
                throw new BridgeException("SaveInOwnFile is not accessible (late-bound) and the typed helper is unavailable in the daemon");
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["saveInOwnFile"] = value;
            return data;
        }

        // twincat_set_independent_file (L8423-8458): config-level mutation.
        private static Json.JObj SetIndependentFile(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            if (!ctx.Payload.Has("enabled")) throw new BridgeException("'enabled' is required (boolean)");
            bool enabled = ctx.Payload.Bool("enabled");

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, path);

            bool got;
            bool prev = SafeBool(delegate() { return (bool)item.SaveInOwnFile; }, out got);
            if (!got)
            {
                throw new BridgeException("SaveInOwnFile is not accessible (late-bound) and the typed helper is unavailable in the daemon");
            }
            item.SaveInOwnFile = enabled;

            ctx.Cache.Invalidate(null);

            var data = new Json.JObj();
            data["path"] = path;
            data["saveInOwnFile"] = enabled;
            data["previous"] = prev;
            return data;
        }

        // ---- node disabled ---------------------------------------------------

        private static string DisabledStateName(int raw)
        {
            if (raw == 0) return "SMDS_NOT_DISABLED";
            if (raw == 1) return "SMDS_DISABLED";
            if (raw == 2) return "SMDS_PARENT_DISABLED";
            return "UNKNOWN(" + raw.ToString(CultureInfo.InvariantCulture) + ")";
        }

        // twincat_get_node_disabled (L8460-8482).
        private static Json.JObj GetNodeDisabled(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, path);
            int raw = ComHelpers.SafeInt(delegate() { return item.Disabled; });

            var data = new Json.JObj();
            data["path"] = path;
            data["disabled"] = raw;
            data["state"] = DisabledStateName(raw);
            return data;
        }

        // twincat_set_node_disabled (L8484-8512): MUTATES tree item -> invalidate path.
        private static Json.JObj SetNodeDisabled(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            PathUtil.AssertNotSafetyPath(path);
            if (!ctx.Payload.Has("disabled")) throw new BridgeException("'disabled' is required (boolean)");
            bool disabled = ctx.Payload.Bool("disabled");

            ctx.Dte(true);
            dynamic sysManager = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sysManager, path);
            int prev = ComHelpers.SafeInt(delegate() { return item.Disabled; });
            int newVal = disabled ? 1 : 0;
            item.Disabled = newVal;

            ctx.Cache.Invalidate(path);

            var data = new Json.JObj();
            data["path"] = path;
            data["disabled"] = newVal;
            data["state"] = DisabledStateName(newVal);
            data["previous"] = prev;
            return data;
        }

        // Get-SafeValue { [bool]$x } with a "got a value" flag (PS distinguishes
        // $null -ne $raw to decide whether the late-bound property answered).
        private static bool SafeBool(Func<bool> f, out bool got)
        {
            try { bool v = f(); got = true; return v; }
            catch { got = false; return false; }
        }
    }
}
