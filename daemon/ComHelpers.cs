using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Te1000Daemon
{
    // Shared COM utility methods used by every action handler. Each maps 1:1 to a
    // PS bridge helper (function name noted). All run on the STA worker thread.
    public static class ComHelpers
    {
        // Is-RetryableComError (L500-507): RPC_E_CALL_REJECTED (-2147418111) or
        // RPC_E_SERVERCALL_RETRYLATER (-2147023174).
        public static bool IsRetryableComError(Exception ex)
        {
            if (ex == null) return false;
            int code = ex.HResult;
            return code == -2147418111 || code == -2147023174;
        }

        // Get-ErrorCode (L43-48): "0x{HRESULT:X8}".
        public static string ErrorCode(Exception ex)
        {
            if (ex == null) return "";
            return "0x" + ((uint)ex.HResult).ToString("X8", CultureInfo.InvariantCulture);
        }

        // Get-SafeValue (L50-62): run a func, swallow exceptions, return null.
        public static T Safe<T>(Func<T> f)
        {
            try { return f(); } catch { return default(T); }
        }

        public static string SafeStr(Func<object> f)
        {
            try { var v = f(); return v == null ? null : Convert.ToString(v, CultureInfo.InvariantCulture); }
            catch { return null; }
        }

        public static int SafeInt(Func<object> f, int dflt = 0)
        {
            try
            {
                var v = f();
                if (v == null) return dflt;
                return Convert.ToInt32(v, CultureInfo.InvariantCulture);
            }
            catch { return dflt; }
        }

        // Invoke-WithRetry (L509-531): retry a func on retryable COM errors.
        public static T WithRetry<T>(Func<T> f, int attempts = 30, int delayMs = 500)
        {
            for (int i = 1; i <= attempts; i++)
            {
                try { return f(); }
                catch (Exception ex)
                {
                    if (IsRetryableComError(ex) && i < attempts) { System.Threading.Thread.Sleep(delayMs); continue; }
                    throw;
                }
            }
            throw new BridgeException("retry exhausted");
        }

        // Get-TreeItem (L3039-3047): LookupTreeItem; throw if not found.
        public static dynamic GetTreeItem(dynamic sysManager, string treePath)
        {
            dynamic item = sysManager.LookupTreeItem(treePath);
            if (item == null) throw new BridgeException("Tree item not found: " + treePath);
            return item;
        }

        public static dynamic TryGetTreeItem(dynamic sysManager, string treePath)
        {
            try { return sysManager.LookupTreeItem(treePath); }
            catch { return null; }
        }

        public static int ChildCount(dynamic treeItem)
        {
            try { return (int)treeItem.ChildCount; } catch { return 0; }
        }

        public static dynamic Child(dynamic treeItem, int index)
        {
            try { return treeItem.Child(index); } catch { return null; }
        }

        // ConsumeXml with GetLastXmlError surfacing (used by many set_xml handlers).
        public static void ConsumeXml(dynamic item, string xml)
        {
            try { item.ConsumeXml(xml); }
            catch (Exception ex)
            {
                string xmlError = null;
                try { xmlError = (string)item.GetLastXmlError(); } catch { }
                if (!string.IsNullOrEmpty(xmlError)) throw new BridgeException("ConsumeXml failed: " + xmlError);
                throw new BridgeException(ex.Message);
            }
        }

        public static string ProduceXml(dynamic item)
        {
            try { return (string)item.ProduceXml(); } catch (Exception ex) { throw new BridgeException(ex.Message); }
        }

        // Convert-TreeItem (L3300-3323): standard tree-item summary object.
        public static Json.JObj ConvertTreeItem(dynamic treeItem)
        {
            object subType = null;
            try { subType = treeItem.SubType; }
            catch { try { subType = treeItem.ItemSubType; } catch { } }

            var o = new Json.JObj();
            o["name"] = SafeStr(() => treeItem.Name);
            o["pathName"] = SafeStr(() => treeItem.PathName);
            o["itemType"] = SafeIntObj(() => treeItem.ItemType);
            o["subType"] = subType == null ? null : (object)ToInt(subType);
            o["childCount"] = ChildCount(treeItem);
            return o;
        }

        private static object SafeIntObj(Func<object> f)
        {
            try { var v = f(); return v == null ? (object)null : ToInt(v); } catch { return null; }
        }

        public static int ToInt(object v)
        {
            if (v is int) return (int)v;
            return Convert.ToInt32(v, CultureInfo.InvariantCulture);
        }

        // Strip-TreeImage (L456-467): drop <TreeImageData16x14>...</...> blobs.
        public static string StripTreeImage(string xml)
        {
            if (string.IsNullOrEmpty(xml)) return xml;
            return Regex.Replace(xml, "<TreeImageData16x14>.*?</TreeImageData16x14>", "", RegexOptions.Singleline);
        }

        // Get-TwinCatVariablePathCandidates (L3373-3406): produce dot->^ variants
        // of the last segment (PLC subfield auto-resolution), longest-dot-suffix
        // first. The original path is always first.
        public static List<string> VariablePathCandidates(string variablePath)
        {
            var candidates = new List<string>();
            if (!string.IsNullOrWhiteSpace(variablePath)) candidates.Add(variablePath);
            if (string.IsNullOrWhiteSpace(variablePath)) return candidates;

            var parts = variablePath.Split('^');
            if (parts.Length < 1) return candidates;
            string last = parts[parts.Length - 1];

            var dotIdx = new List<int>();
            for (int k = 0; k < last.Length; k++) if (last[k] == '.') dotIdx.Add(k);

            for (int i = dotIdx.Count - 1; i >= 0; i--)
            {
                var chars = last.ToCharArray();
                for (int j = i; j < dotIdx.Count; j++) chars[dotIdx[j]] = '^';
                var variant = (string[])parts.Clone();
                variant[variant.Length - 1] = new string(chars);
                string candidate = string.Join("^", variant);
                if (!candidates.Contains(candidate)) candidates.Add(candidate);
            }
            return candidates;
        }

        // Resolve-TwinCatVariablePath: return the first candidate path that
        // resolves to a live tree item, else the original.
        public static string ResolveVariablePath(dynamic sysManager, string variablePath)
        {
            foreach (var cand in VariablePathCandidates(variablePath))
            {
                var item = TryGetTreeItem(sysManager, cand);
                if (item != null) return cand;
            }
            return variablePath;
        }

        public static dynamic ResolveVariableItem(dynamic sysManager, string variablePath, out string resolvedPath)
        {
            foreach (var cand in VariablePathCandidates(variablePath))
            {
                var item = TryGetTreeItem(sysManager, cand);
                if (item != null) { resolvedPath = cand; return item; }
            }
            resolvedPath = variablePath;
            throw new BridgeException("Tree item not found: " + variablePath);
        }
    }
}
