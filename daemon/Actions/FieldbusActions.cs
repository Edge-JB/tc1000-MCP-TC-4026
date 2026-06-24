using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Te1000Daemon
{
    // tc_fieldbus actions ported from te1000-bridge.ps1 (L8520-8941). NON-EtherCAT
    // fieldbus masters/slaves/boxes (PROFINET / PROFIBUS / CANopen / DeviceNet /
    // EAP) created via late-bound CreateChild, plus resource listing/claiming,
    // GSD boxes, EAP netvars, station addresses, DBC import, and raw XML get/set.
    // OFFLINE config only — no cell write. C#5-clean (no interpolation, no out var,
    // no expression-bodied members). Mutations invalidate the affected subtree.
    internal static class FieldbusActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["fieldbus_create_device"] = CreateDevice;
            h["fieldbus_create_devices"] = CreateDevices;
            h["fieldbus_list_resources"] = ListResources;
            h["fieldbus_claim_resources"] = ClaimResources;
            h["fieldbus_create_gsd_box"] = CreateGsdBox;
            h["fieldbus_add_netvar"] = AddNetvar;
            h["fieldbus_set_station_address"] = SetStationAddress;
            h["fieldbus_import_dbc"] = ImportDbc;
            h["fieldbus_get_xml"] = GetXml;
            h["fieldbus_set_xml"] = SetXml;
        }

        // --- fieldbus_create_device (L8520-8542) -----------------------------
        private static Json.JObj CreateDevice(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();

            string parentPath; // out param from the helper for cache invalidation
            Json.JObj created = InvokeFieldbusCreateDevice(ctx, sm, ctx.Payload, out parentPath);
            ctx.Cache.Invalidate(parentPath);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["parentPath"] = created.Str("parentPath");
            data["child"] = created["child"];
            data["claimed"] = created["claimed"];
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_create_devices (L8544-8602) ----------------------------
        // Continue-on-error batch {count, succeeded, failed, results[]} with an
        // optional global File.SaveAll at the end.
        private static Json.JObj CreateDevices(ActionContext ctx)
        {
            Json.JArr creates = ctx.Payload.Arr("creates");
            if (creates == null || creates.Count == 0) throw new BridgeException("creates is required");
            bool save = false;
            if (ctx.Payload.Has("save")) save = ctx.Payload.Bool("save");

            dynamic sm = ctx.SysManager();
            var results = new Json.JArr();
            int succeeded = 0;
            int failed = 0;

            foreach (object entryObj in creates)
            {
                Json.JObj entry = entryObj as Json.JObj;

                string entryParent = (entry != null && entry.Has("parent") && !string.IsNullOrWhiteSpace(entry.Str("parent")))
                    ? entry.Str("parent") : "TIID";
                string entryName = (entry != null && entry.Has("name")) ? entry.Str("name") : null;

                try
                {
                    string parentPath;
                    Json.JObj created = InvokeFieldbusCreateDevice(ctx, sm, entry, out parentPath);
                    ctx.Cache.Invalidate(parentPath);
                    succeeded++;
                    var r = new Json.JObj();
                    r["parent"] = created.Str("parentPath");
                    r["name"] = entryName;
                    r["ok"] = true;
                    r["child"] = created["child"];
                    r["claimed"] = created["claimed"];
                    results.Add(r);
                }
                catch (Exception ex)
                {
                    failed++;
                    var r = new Json.JObj();
                    r["parent"] = entryParent;
                    r["name"] = entryName;
                    r["ok"] = false;
                    r["error"] = ex.Message;
                    results.Add(r);
                }
            }

            var data = new Json.JObj();
            data["count"] = creates.Count;
            data["succeeded"] = succeeded;
            data["failed"] = failed;
            data["results"] = results;
            if (save)
            {
                bool saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
                data["saved"] = saved;
            }
            return data;
        }

        // --- fieldbus_list_resources (L8604-8642) ----------------------------
        // Beckhoff pages disagree on the property name (PROFIBUS: ResourcesCount;
        // CANopen: ResourceCount). Probe both via Safe and report which answered.
        private static Json.JObj ListResources(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, path);

            string countStr = ComHelpers.SafeStr(delegate { return item.ResourcesCount; });
            string prop = "ResourcesCount";
            if (countStr == null)
            {
                countStr = ComHelpers.SafeStr(delegate { return item.ResourceCount; });
                prop = "ResourceCount";
            }

            object count;
            if (countStr == null)
            {
                count = null;
                prop = null;
            }
            else
            {
                // Coerce to int when parseable; otherwise keep the raw value.
                int parsed;
                if (int.TryParse(countStr, out parsed)) count = parsed;
                else count = countStr;
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["resourcesCount"] = count;
            data["property"] = prop;
            return data;
        }

        // --- fieldbus_claim_resources (L8644-8685) ---------------------------
        private static Json.JObj ClaimResources(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("index")) throw new BridgeException("index is required");
            int index = ctx.Payload.Int("index", 0);
            PathUtil.AssertNotSafetyPath(path);

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            try
            {
                item.ClaimResources(index);
            }
            catch (Exception ex)
            {
                string xmlError = ComHelpers.SafeStr(delegate { return item.GetLastXmlError(); });
                if (!string.IsNullOrWhiteSpace(xmlError)) throw new BridgeException("ClaimResources failed: " + xmlError);
                throw new BridgeException(ex.Message);
            }

            ctx.Cache.Invalidate(path);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["index"] = index;
            data["claimed"] = true;
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_create_gsd_box (L8687-8733) ----------------------------
        // PROFINET GSD device box. vInfo syntax:
        // PathToGSDfile#ModuleIdentNumber#BoxFlags#DAPNumber. The device subType
        // (e.g. 115/118/142/143) is NOT auto-defaulted — caller must pass it.
        private static Json.JObj CreateGsdBox(ActionContext ctx)
        {
            string controllerPath = ctx.Payload.Str("controllerPath");
            string name = ctx.Payload.Str("name");
            string gsdPath = ctx.Payload.Str("gsdPath");
            string moduleIdentNumber = ctx.Payload.Str("moduleIdentNumber");
            if (string.IsNullOrWhiteSpace(controllerPath)) throw new BridgeException("controllerPath is required");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(gsdPath)) throw new BridgeException("gsdPath is required");
            if (string.IsNullOrWhiteSpace(moduleIdentNumber)) throw new BridgeException("moduleIdentNumber is required");
            if (!ctx.Payload.Has("subType"))
                throw new BridgeException("subType is required for create_gsd_box (PROFINET device subType, e.g. 115/118/142/143; depends on the controller variant). Confirm against the GSD how-to before use.");
            int subType = ctx.Payload.Int("subType", 0);
            PathUtil.AssertNotSafetyPath(controllerPath);

            int flags = (ctx.Payload.Has("boxFlags")) ? ctx.Payload.Int("boxFlags", 0) : 0;
            string dap = (ctx.Payload.Has("dapNumber") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("dapNumber")))
                ? ctx.Payload.Str("dapNumber") : "";
            string before = (ctx.Payload.Has("before") && ctx.Payload.Truthy("before")) ? ctx.Payload.Str("before") : "";

            // Beckhoff GSD vInfo syntax: PathToGSDfile#ModuleIdentNumber#BoxFlags#DAPNumber
            string vInfo = gsdPath + "#" + moduleIdentNumber + "#" + flags.ToString(CultureInfo.InvariantCulture) + "#" + dap;

            dynamic sm = ctx.SysManager();
            dynamic controller = ComHelpers.GetTreeItem(sm, controllerPath);
            dynamic box = controller.CreateChild(name, subType, before, vInfo);
            AssertWellFormedChild(controller, box, name, subType, controllerPath);
            ctx.Cache.Invalidate(controllerPath);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["controllerPath"] = controllerPath;
            data["box"] = ComHelpers.ConvertTreeItem(box);
            data["vInfo"] = vInfo;
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_add_netvar (L8735-8768) --------------------------------
        // EAP pub/sub variable: SubType 0, dataType passed as vInfo. Resulting
        // ItemType is 35 (publisher) / 36 (subscriber) — informational read-back.
        private static Json.JObj AddNetvar(ActionContext ctx)
        {
            string boxPath = ctx.Payload.Str("boxPath");
            string name = ctx.Payload.Str("name");
            string dataType = ctx.Payload.Str("dataType");
            if (string.IsNullOrWhiteSpace(boxPath)) throw new BridgeException("boxPath is required");
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (string.IsNullOrWhiteSpace(dataType)) throw new BridgeException("dataType is required");
            PathUtil.AssertNotSafetyPath(boxPath);
            string before = (ctx.Payload.Has("before") && ctx.Payload.Truthy("before")) ? ctx.Payload.Str("before") : "";

            dynamic sm = ctx.SysManager();
            dynamic box = ComHelpers.GetTreeItem(sm, boxPath);
            dynamic var = box.CreateChild(name, 0, before, dataType);
            AssertWellFormedChild(box, var, name, 0, boxPath);
            ctx.Cache.Invalidate(boxPath);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["boxPath"] = boxPath;
            data["var"] = ComHelpers.ConvertTreeItem(var);
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_set_station_address (L8770-8828) -----------------------
        // The exact station-address XML element is not pinned in the docs, so
        // discover it first: ProduceXml(false), locate an element whose name
        // contains "Station" + an Address/No/Number sibling, then ConsumeXml a
        // minimal envelope.
        private static Json.JObj SetStationAddress(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (!ctx.Payload.Has("address")) throw new BridgeException("address is required");
            int address = ctx.Payload.Int("address", 0);
            PathUtil.AssertNotSafetyPath(path);

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, path);

            string current = ComHelpers.SafeStr(delegate { return item.ProduceXml(false); });
            string element = null;
            if (!string.IsNullOrWhiteSpace(current))
            {
                Match m = Regex.Match(current, @"<(?<el>\w*Station(Address|No|Number)\w*)>");
                if (m.Success) element = m.Groups["el"].Value;
            }
            if (string.IsNullOrWhiteSpace(element))
                throw new BridgeException("Could not discover the station-address XML element from ProduceXml for '" + path + "'. Use tc_fieldbus get_xml to inspect the node and set_xml to apply the correct element (the bare ConsumeXml(number) form is unverified and is not shipped).");

            string addrStr = address.ToString(CultureInfo.InvariantCulture);
            string xml = "<TreeItem><" + element + ">" + addrStr + "</" + element + "></TreeItem>";
            try
            {
                item.ConsumeXml(xml);
            }
            catch (Exception ex)
            {
                string xmlError = ComHelpers.SafeStr(delegate { return item.GetLastXmlError(); });
                if (!string.IsNullOrWhiteSpace(xmlError)) throw new BridgeException("ConsumeXml failed: " + xmlError);
                throw new BridgeException(ex.Message);
            }

            ctx.Cache.Invalidate(path);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["address"] = address;
            data["element"] = element;
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_import_dbc (L8830-8887) --------------------------------
        // CanOpenMaster/ImportDbcFile config import (needs TC3.1 build >= 4018).
        private static Json.JObj ImportDbc(ActionContext ctx)
        {
            string masterPath = ctx.Payload.Str("masterPath");
            string fileName = ctx.Payload.Str("fileName");
            if (string.IsNullOrWhiteSpace(masterPath)) throw new BridgeException("masterPath is required");
            if (string.IsNullOrWhiteSpace(fileName)) throw new BridgeException("fileName is required");
            PathUtil.AssertNotSafetyPath(masterPath);

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, masterPath);

            var sb = new StringBuilder();
            sb.Append("<TreeItem><CanOpenMaster><ImportDbcFile>");
            sb.Append("<FileName>" + PathUtil.XmlEscape(fileName) + "</FileName>");

            string[] flags = new string[] { "importExtendedMessages", "importMultiplexedDataMessages", "keepUnchangedMessages", "communicateWithSlavesFromDbcFile" };
            foreach (string flag in flags)
            {
                if (ctx.Payload.Has(flag))
                {
                    string tag;
                    switch (flag)
                    {
                        case "importExtendedMessages": tag = "ImportExtendedMessages"; break;
                        case "importMultiplexedDataMessages": tag = "ImportMultiplexedDataMessages"; break;
                        case "keepUnchangedMessages": tag = "KeepUnchangedMessages"; break;
                        case "communicateWithSlavesFromDbcFile": tag = "CommunicateWithSlavesFromDbcFile"; break;
                        default: tag = flag; break;
                    }
                    string val = ctx.Payload.Bool(flag) ? "true" : "false";
                    sb.Append("<" + tag + ">" + val + "</" + tag + ">");
                }
            }
            sb.Append("</ImportDbcFile></CanOpenMaster></TreeItem>");
            string xml = sb.ToString();

            try
            {
                item.ConsumeXml(xml);
            }
            catch (Exception ex)
            {
                string xmlError = ComHelpers.SafeStr(delegate { return item.GetLastXmlError(); });
                if (!string.IsNullOrWhiteSpace(xmlError)) throw new BridgeException("ImportDbcFile ConsumeXml failed: " + xmlError + " (requires TC3.1 build >= 4018)");
                throw new BridgeException(ex.Message);
            }

            ctx.Cache.Invalidate(masterPath);

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["masterPath"] = masterPath;
            data["fileName"] = fileName;
            data["imported"] = true;
            data["saved"] = saved;
            return data;
        }

        // --- fieldbus_get_xml (L8889-8904) -----------------------------------
        private static Json.JObj GetXml(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");

            dynamic sm = ctx.SysManager();
            dynamic item = ctx.Cache.LookupItem(sm, path);
            string xml = (string)item.ProduceXml(false);

            var data = new Json.JObj();
            data["path"] = path;
            data["xml"] = xml;
            return data;
        }

        // --- fieldbus_set_xml (L8906-8939) -----------------------------------
        // ConsumeXml the raw envelope (GetLastXmlError surfaced) and optionally
        // echo ProduceXml(false). PS does NOT strip the tree image here.
        private static Json.JObj SetXml(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            string xml = ctx.Payload.Str("xml");
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(xml)) throw new BridgeException("xml is required");
            PathUtil.AssertNotSafetyPath(path);
            bool returnXml = ctx.Payload.Has("returnXml") && ctx.Payload.Bool("returnXml");

            dynamic sm = ctx.SysManager();
            // Set-TreeItemXml: ConsumeXml with GetLastXmlError surfacing.
            dynamic item = ComHelpers.GetTreeItem(sm, path);
            ComHelpers.ConsumeXml(item, xml);
            ctx.Cache.Invalidate(path);

            object echo = null;
            if (returnXml)
            {
                echo = ComHelpers.SafeStr(delegate { return item.ProduceXml(false); });
            }

            object saved = null;
            if (ctx.Payload.Has("save") && ctx.Payload.Bool("save"))
            {
                saved = false;
                try { ctx.Dte().ExecuteCommand("File.SaveAll"); saved = true; }
                catch { saved = false; }
            }

            var data = new Json.JObj();
            data["path"] = path;
            data["applied"] = true;
            data["xml"] = echo;
            data["saved"] = saved;
            return data;
        }

        // ===================================================================
        // private helpers
        // ===================================================================

        // Invoke-FieldbusCreateDevice (L3332-3371): shared CreateChild path for
        // NON-EtherCAT fieldbus masters/slaves/boxes. CreateChild(name, subType,
        // before, vInfo) then Assert-WellFormedChild so a wrong subType/vInfo
        // "ghost" is cleaned up and surfaced. Optional ClaimResources(claimIndex)
        // (OFFLINE config binding — NOT a cell write; failures are swallowed into
        // claimed=false). Returns {parentPath, child, claimed}; parentPath also
        // emitted via the out param so the caller can invalidate the cache.
        private static Json.JObj InvokeFieldbusCreateDevice(ActionContext ctx, dynamic sysManager, Json.JObj entry, out string parentPath)
        {
            if (entry == null) entry = new Json.JObj();

            string name = entry.Has("name") ? entry.Str("name") : null;
            if (string.IsNullOrWhiteSpace(name)) throw new BridgeException("name is required");
            if (!entry.Has("subType")) throw new BridgeException("subType is required");
            int subType = entry.Int("subType", 0);

            parentPath = (entry.Has("parent") && !string.IsNullOrWhiteSpace(entry.Str("parent")))
                ? entry.Str("parent") : "TIID";
            PathUtil.AssertNotSafetyPath(parentPath);
            string before = (entry.Has("before") && entry.Truthy("before")) ? entry.Str("before") : "";
            string vInfo = (entry.Has("vInfo") && !string.IsNullOrWhiteSpace(entry.Str("vInfo"))) ? entry.Str("vInfo") : null;

            dynamic parent = ComHelpers.GetTreeItem(sysManager, parentPath);
            dynamic child = parent.CreateChild(name, subType, before, vInfo);
            AssertWellFormedChild(parent, child, name, subType, parentPath);

            object claimed = null;
            if (entry.Has("claimIndex"))
            {
                int claimIndex = entry.Int("claimIndex", 0);
                try
                {
                    // ClaimResources lives on ITcSmTreeItem5/2; late-bound directly.
                    // OFFLINE config binding of the node to underlying FC/EL hardware.
                    child.ClaimResources(claimIndex);
                    claimed = true;
                }
                catch
                {
                    claimed = false;
                }
            }

            var result = new Json.JObj();
            result["parentPath"] = parentPath;
            result["child"] = ComHelpers.ConvertTreeItem(child);
            result["claimed"] = claimed;
            return result;
        }

        // Assert-WellFormedChild (L3192-3241): validate a child returned by
        // CreateChild; on a malformed "ghost" do best-effort cleanup (DeleteChild by
        // the actual non-blank name) and THROW a descriptive error. Returns on
        // success. (Private copy kept in this file per the porting brief.)
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
            // Read back identity defensively — a ghost can throw on property access.
            string childActualName = ComHelpers.SafeStr(delegate { return child.Name; });
            string childPath = ComHelpers.SafeStr(delegate { return child.PathName; });

            string reason = null;
            if (child == null)
            {
                reason = "CreateChild returned null";
            }
            else if (string.IsNullOrWhiteSpace(childActualName))
            {
                reason = "returned child has a blank name";
            }
            else if (childActualName != requestedName)
            {
                reason = "returned child name '" + childActualName + "' does not match requested name '" + requestedName + "'";
            }
            else
            {
                string expectedPath = parentPath + "^" + requestedName;
                if (!string.IsNullOrWhiteSpace(childPath) && childPath != expectedPath)
                {
                    reason = "returned child path '" + childPath + "' is not under requested parent (expected '" + expectedPath + "')";
                }
            }

            if (reason == null) return;

            // Best-effort cleanup: only delete by name when we have a non-blank name.
            if (!string.IsNullOrWhiteSpace(childActualName))
            {
                try { parent.DeleteChild(childActualName); }
                catch { }
            }

            throw new BridgeException("CreateChild produced a malformed child (name='" + childActualName + "', path='" + childPath +
                "') for requested name='" + requestedName + "', subType=" + subType.ToString(CultureInfo.InvariantCulture) +
                " under '" + parentPath + "' (" + reason + "). This usually means the subType/createInfo is not valid for this parent " +
                "(EtherCAT boxes typically require a proper createInfo). No usable child was created. If a stray blank-named child remains, " +
                "remove it in the XAE GUI or via close-without-save.");
        }
    }
}
