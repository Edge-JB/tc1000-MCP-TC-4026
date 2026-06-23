using System;
using System.Text.RegularExpressions;

namespace Te1000Daemon
{
    // Pure '^'-path helpers ported from te1000-bridge.ps1 (no COM). The TISC
    // safety rejection MUST match the PS bridge byte-for-byte (Assert-NotSafetyPath
    // L1576) — nothing in this toolchain may write toward the EL6910 safety system.
    public static class PathUtil
    {
        // Assert-NotSafetyPath (L1576-1587): reject any path rooted at the TISC
        // safety project. Throws BridgeException with the exact PS message.
        public static void AssertNotSafetyPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            if (Regex.IsMatch(path, @"^\s*TISC(\^|$)"))
            {
                throw new BridgeException(
                    "Refused: '" + path + "' targets the TISC safety project. plc_pou must not author toward the safety system (project policy: nothing writes toward safety).");
            }
        }

        public sealed class ParentName
        {
            public string Parent;
            public string Name;
        }

        // Split-PlcObjectPath (L1593-1610): split a '^'-joined path into
        // { parent, name }. Throws when there is no parent^name structure.
        public static ParentName SplitObjectPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            int idx = path.LastIndexOf('^');
            if (idx < 1 || idx >= path.Length - 1)
                throw new BridgeException("path '" + path + "' must be a child object (contain '^' with a parent and a trailing name segment)");
            return new ParentName { Parent = path.Substring(0, idx), Name = path.Substring(idx + 1) };
        }

        // Assert-PlcMoveLegal (L1612-1633): reject no-op / into-self / into-subtree moves.
        public static void AssertMoveLegal(string path, string newParent)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new BridgeException("path is required");
            if (string.IsNullOrWhiteSpace(newParent)) throw new BridgeException("newParent is required");
            var split = SplitObjectPath(path);
            if (newParent == split.Parent)
                throw new BridgeException("newParent '" + newParent + "' is already the current parent of '" + path + "' (no-op move refused)");
            if (newParent == path)
                throw new BridgeException("newParent '" + newParent + "' is the object itself (cannot move an object into itself)");
            if (newParent.StartsWith(path + "^", StringComparison.Ordinal))
                throw new BridgeException("newParent '" + newParent + "' is a descendant of '" + path + "' (cannot move an object into its own subtree)");
        }

        // XML-escape a tree-item name (used by rename ConsumeXml envelopes).
        public static string XmlEscape(string s)
        {
            if (s == null) return "";
            return s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        }
    }
}
