using System;
using System.Collections.Generic;
using System.Globalization;
using System.Xml;

namespace Te1000Daemon
{
    // License actions operate on the TIRC^License tree node (ProduceXml read /
    // ConsumeXml + CreateChild mutate). Variant actions operate on the
    // sysManager itself (ProjectVariantConfig / CurrentProjectVariant on
    // iTcSysManager14) and on a tree item's PvDisable/Disabled flags
    // (ITcSmTreeItem9). All accessed late-bound on the COM object.
    internal static class LicenseVariantActions
    {
        public static void Register(Dictionary<string, ActionHandler> h)
        {
            h["twincat_license_list_devices"] = LicenseListDevices;
            h["twincat_license_add_device"] = LicenseAddDevice;
            h["twincat_license_activate_response"] = LicenseActivateResponse;
            h["twincat_get_variant_config"] = GetVariantConfig;
            h["twincat_get_current_variant"] = GetCurrentVariant;
            h["twincat_set_variant_config"] = SetVariantConfig;
            h["twincat_set_current_variant"] = SetCurrentVariant;
            h["twincat_set_item_variant_disable"] = SetItemVariantDisable;
        }

        // L9561-9592: read-only. ProduceXml on TIRC^License, parse //LicenseDevice
        // nodes. On TC3.1 < 4022.4 the blob has no device support -> empty list.
        private static Json.JObj LicenseListDevices(ActionContext ctx)
        {
            bool rawFlag = ctx.Payload.Has("raw") && ctx.Payload.Bool("raw", false);

            dynamic sm = ctx.SysManager();
            dynamic license = ctx.Cache.LookupItem(sm, "TIRC^License");
            string xmlText = ComHelpers.ProduceXml(license);

            var devices = new Json.JArr();
            try
            {
                var doc = new XmlDocument();
                doc.LoadXml(xmlText);
                XmlNodeList nodes = doc.SelectNodes("//LicenseDevice");
                if (nodes != null)
                {
                    foreach (XmlNode d in nodes)
                    {
                        var dev = new Json.JObj();
                        dev["name"] = AttrOrEmpty(d, "Name");
                        dev["pathName"] = AttrOrEmpty(d, "PathName");
                        dev["typeName"] = AttrOrEmpty(d, "TypeName");
                        dev["objectId"] = AttrOrEmpty(d, "ObjectID");
                        devices.Add(dev);
                    }
                }
            }
            catch
            {
                devices = new Json.JArr();
            }

            var data = new Json.JObj();
            data["treePath"] = "TIRC^License";
            data["devices"] = devices;
            if (rawFlag) data["xml"] = ComHelpers.StripTreeImage(xmlText);
            return data;
        }

        // PS reads $d.Name etc. which (for [xml] elements) resolves either an
        // attribute or a child element of that name. License device fields are
        // emitted as attributes; fall back to child element text otherwise.
        private static string AttrOrEmpty(XmlNode node, string name)
        {
            if (node == null) return "";
            XmlElement el = node as XmlElement;
            if (el != null && el.HasAttribute(name)) return el.GetAttribute(name);
            XmlNode child = node.SelectSingleNode(name);
            if (child != null) return child.InnerText;
            return "";
        }

        // L9594-9622: MUTATE. CreateChild(name, 0, '', device) under TIRC^License,
        // validate via Assert-WellFormedChild. Not confirm-gated (mirrors create).
        private static Json.JObj LicenseAddDevice(ActionContext ctx)
        {
            string name = ctx.Payload.Str("name");
            string device = ctx.Payload.Str("device");
            if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(device))
            {
                throw new BridgeException("name and device are required");
            }

            dynamic sm = ctx.SysManager();
            dynamic license = ComHelpers.GetTreeItem(sm, "TIRC^License");
            dynamic child = license.CreateChild(name, 0, "", device);

            AssertWellFormedChild(license, child, name, 0, "TIRC^License");

            ctx.Cache.Invalidate("TIRC^License");

            var data = new Json.JObj();
            data["parentPath"] = "TIRC^License";
            data["child"] = ComHelpers.ConvertTreeItem(child);
            return data;
        }

        // L9624-9657: MUTATE (license-activation state change). ConsumeXml the
        // ActivateResponseFile command on TIRC^License. The PS handler itself
        // re-checks the ALLOW_LICENSE_ACTIVATE token (defense-in-depth) -> keep it.
        private static Json.JObj LicenseActivateResponse(ActionContext ctx)
        {
            string path = ctx.Payload.Str("path");
            if (string.IsNullOrWhiteSpace(path))
            {
                throw new BridgeException("path is required");
            }

            string oemGuid = "0";
            if (ctx.Payload.Has("oemGuid") && !string.IsNullOrWhiteSpace(ctx.Payload.Str("oemGuid")))
            {
                oemGuid = ctx.Payload.Str("oemGuid");
            }

            if (ctx.Payload.Str("confirm") != "ALLOW_LICENSE_ACTIVATE")
            {
                throw new BridgeException("Blocked. license activate_response requires confirm=\"ALLOW_LICENSE_ACTIVATE\".");
            }

            string escPath = PathUtil.XmlEscape(path);
            string escGuid = PathUtil.XmlEscape(oemGuid);
            string xml = "<TreeItem><ItemName>License</ItemName><PathName>TIRC^License</PathName>" +
                "<ItemType>59</ItemType><LicenseDef><Commands><ActivateResponseFile><Path>" +
                escPath + "</Path><OemGuid>" + escGuid +
                "</OemGuid></ActivateResponseFile></Commands></LicenseDef></TreeItem>";

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, "TIRC^License");
            ComHelpers.ConsumeXml(item, xml);
            ctx.Cache.Invalidate("TIRC^License");

            var data = new Json.JObj();
            data["treePath"] = "TIRC^License";
            data["path"] = path;
            data["activated"] = true;
            return data;
        }

        // L9666-9675: read-only. sysManager.ProjectVariantConfig (iTcSysManager14).
        private static Json.JObj GetVariantConfig(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string xml = ComHelpers.SafeStr(delegate { return sm.ProjectVariantConfig; });
            var data = new Json.JObj();
            data["xml"] = xml;
            return data;
        }

        // L9677-9686: read-only. sysManager.CurrentProjectVariant.
        private static Json.JObj GetCurrentVariant(ActionContext ctx)
        {
            dynamic sm = ctx.SysManager();
            string cur = ComHelpers.SafeStr(delegate { return sm.CurrentProjectVariant; });
            var data = new Json.JObj();
            data["current"] = cur;
            return data;
        }

        // L9688-9714: MUTATE. Set sysManager.ProjectVariantConfig = xml, optional
        // save, read back. No tree path -> invalidate whole cache (null).
        private static Json.JObj SetVariantConfig(ActionContext ctx)
        {
            string xml = ctx.Payload.Str("xml");
            if (string.IsNullOrWhiteSpace(xml))
            {
                throw new BridgeException("xml is required");
            }
            bool save = ctx.Payload.Has("save") && ctx.Payload.Bool("save", false);

            dynamic sm = ctx.SysManager();
            try
            {
                sm.ProjectVariantConfig = xml;
            }
            catch (Exception ex)
            {
                throw new BridgeException("Setting ProjectVariantConfig failed: " + ex.Message);
            }
            if (save) ctx.Dte().ExecuteCommand("File.SaveAll");

            ctx.Cache.Invalidate(null);

            string readback = ComHelpers.SafeStr(delegate { return sm.ProjectVariantConfig; });

            var data = new Json.JObj();
            data["defined"] = true;
            data["xml"] = readback;
            data["saved"] = save;
            return data;
        }

        // L9716-9740: MUTATE. Set sysManager.CurrentProjectVariant = variant,
        // optional save, verify the read-back matches. No tree path -> invalidate all.
        private static Json.JObj SetCurrentVariant(ActionContext ctx)
        {
            string variant = ctx.Payload.Str("variant");
            if (string.IsNullOrWhiteSpace(variant))
            {
                throw new BridgeException("variant is required");
            }
            bool save = ctx.Payload.Has("save") && ctx.Payload.Bool("save", false);

            dynamic sm = ctx.SysManager();
            sm.CurrentProjectVariant = variant;
            if (save) ctx.Dte().ExecuteCommand("File.SaveAll");

            ctx.Cache.Invalidate(null);

            string cur = (string)sm.CurrentProjectVariant;
            if (cur != variant)
            {
                throw new BridgeException("CurrentProjectVariant is '" + cur + "' after setting '" + variant +
                    "' - variant/group may not exist in the variant config");
            }

            var data = new Json.JObj();
            data["current"] = cur;
            data["saved"] = save;
            return data;
        }

        // L9742-9773: MUTATE. Toggle a tree item's PvDisable + Disabled flags
        // (ITcSmTreeItem9). Refuses TISC (safety) paths by policy. disable
        // defaults true; index.js sends disable:false for the enable verb.
        private static Json.JObj SetItemVariantDisable(ActionContext ctx)
        {
            string treePath = ctx.Payload.Str("treePath");
            if (string.IsNullOrWhiteSpace(treePath))
            {
                throw new BridgeException("treePath is required");
            }
            // Safety policy: never address the TISC safety project. Mirrors the PS
            // regex ^\s*TISC(\^|$).
            string trimmed = treePath.TrimStart();
            // Case-INSENSITIVE to match the PS bridge and TwinCAT's case-insensitive
            // tree-root resolution (a lowercase `tisc^...` must be refused too).
            if (string.Equals(trimmed, "TISC", StringComparison.OrdinalIgnoreCase)
                || trimmed.StartsWith("TISC^", StringComparison.OrdinalIgnoreCase))
            {
                throw new BridgeException("Refused: variant operations on the safety project (TISC) are disallowed by policy.");
            }

            // Default true; disable becomes false ONLY when disable is present and == false.
            bool disable = !(ctx.Payload.Has("disable") && ctx.Payload.Bool("disable", true) == false);
            bool save = ctx.Payload.Has("save") && ctx.Payload.Bool("save", false);

            dynamic sm = ctx.SysManager();
            dynamic item = ComHelpers.GetTreeItem(sm, treePath);
            item.PvDisable = disable;
            item.Disabled = disable ? 1 : 0;
            if (save) ctx.Dte().ExecuteCommand("File.SaveAll");

            ctx.Cache.Invalidate(treePath);

            int state = ComHelpers.SafeInt(delegate { return item.Disabled; });
            bool pv = SafeBool(delegate { return item.PvDisable; });

            var data = new Json.JObj();
            data["path"] = treePath;
            data["pvDisable"] = pv;
            data["disabled"] = state;
            data["saved"] = save;
            return data;
        }

        // Local Get-SafeValue { [bool]$item.PvDisable } equivalent; ComHelpers has
        // SafeStr/SafeInt but no SafeBool, so keep a small private copy.
        private static bool SafeBool(Func<object> f)
        {
            try
            {
                object v = f();
                if (v == null) return false;
                if (v is bool) return (bool)v;
                return Convert.ToBoolean(v, CultureInfo.InvariantCulture);
            }
            catch { return false; }
        }

        // Assert-WellFormedChild (L3192-3241): validate a CreateChild result; on a
        // malformed "ghost" do best-effort cleanup and THROW. (Private copy per brief.)
        private static void AssertWellFormedChild(dynamic parent, dynamic child, string requestedName, int subType, string parentPath)
        {
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
