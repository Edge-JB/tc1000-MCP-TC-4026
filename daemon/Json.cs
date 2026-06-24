using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Te1000Daemon
{
    // Minimal, dependency-free JSON parser + writer. No NuGet, no internet.
    //
    // Parse() returns: JObj (ordered Dictionary<string,object>), JArr
    // (List<object>), string, double, bool, or null.
    //
    // Write() accepts the same plus IDictionary / IEnumerable, and (importantly)
    // null/"" pruning is NOT done here — the PS bridge emitted nulls/empties and
    // index.js prunes them client-side, so we mirror the bridge exactly.
    public static class Json
    {
        // ---- model ----------------------------------------------------------
        // Ordered map so output key order matches the hand-built PS hashtables.
        public sealed class JObj : IEnumerable<KeyValuePair<string, object>>
        {
            private readonly List<string> _keys = new List<string>();
            private readonly Dictionary<string, object> _map = new Dictionary<string, object>(StringComparer.Ordinal);

            public object this[string key]
            {
                get { object v; return _map.TryGetValue(key, out v) ? v : null; }
                set
                {
                    if (!_map.ContainsKey(key)) _keys.Add(key);
                    _map[key] = value;
                }
            }

            public bool Has(string key) { return _map.ContainsKey(key); }
            public bool Remove(string key) { _keys.Remove(key); return _map.Remove(key); }
            public int Count { get { return _keys.Count; } }
            public IEnumerable<string> Keys { get { return _keys; } }

            public JObj Set(string key, object value) { this[key] = value; return this; }

            // Typed accessors (lenient; mirror PS [string]/[int]/[bool] coercion).
            public string Str(string key, string dflt = null)
            {
                object v = this[key];
                if (v == null) return dflt;
                return v as string ?? Convert.ToString(v, CultureInfo.InvariantCulture);
            }
            public bool Bool(string key, bool dflt = false)
            {
                object v = this[key];
                if (v == null) return dflt;
                if (v is bool) return (bool)v;
                if (v is double) return (double)v != 0;
                bool b; return bool.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), out b) ? b : dflt;
            }
            public bool TryBool(string key, out bool value)
            {
                value = false;
                if (!_map.ContainsKey(key) || this[key] == null) return false;
                value = Bool(key);
                return true;
            }
            public int Int(string key, int dflt = 0)
            {
                object v = this[key];
                if (v == null) return dflt;
                if (v is double) return (int)Math.Round((double)v);
                int i; return int.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), NumberStyles.Any, CultureInfo.InvariantCulture, out i) ? i : dflt;
            }
            public long Long(string key, long dflt = 0)
            {
                object v = this[key];
                if (v == null) return dflt;
                if (v is double) return (long)Math.Round((double)v);
                long i; return long.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), NumberStyles.Any, CultureInfo.InvariantCulture, out i) ? i : dflt;
            }
            public JObj Obj(string key) { return this[key] as JObj; }
            public JArr Arr(string key) { return this[key] as JArr; }

            // Mirror PS `if ($payload.x)` truthiness: present, non-null, non-empty-string, non-zero.
            public bool Truthy(string key)
            {
                object v = this[key];
                if (v == null) return false;
                if (v is string) return ((string)v).Length > 0;
                if (v is bool) return (bool)v;
                if (v is double) return (double)v != 0;
                return true;
            }

            public IEnumerator<KeyValuePair<string, object>> GetEnumerator()
            {
                foreach (var k in _keys) yield return new KeyValuePair<string, object>(k, _map[k]);
            }
            IEnumerator IEnumerable.GetEnumerator() { return GetEnumerator(); }
        }

        public sealed class JArr : List<object>
        {
            public JArr() { }
            public JArr(IEnumerable<object> src) : base(src) { }
            public JArr Add2(object v) { Add(v); return this; }
            public string StrAt(int i) { return this[i] as string ?? Convert.ToString(this[i], CultureInfo.InvariantCulture); }
        }

        // ---- writer ---------------------------------------------------------
        public static string Write(object value)
        {
            var sb = new StringBuilder(256);
            WriteValue(sb, value);
            return sb.ToString();
        }

        private static void WriteValue(StringBuilder sb, object v)
        {
            if (v == null) { sb.Append("null"); return; }
            if (v is string) { WriteString(sb, (string)v); return; }
            if (v is bool) { sb.Append((bool)v ? "true" : "false"); return; }
            if (v is JObj) { WriteObj(sb, (JObj)v); return; }
            if (v is JArr) { WriteArr(sb, (JArr)v); return; }
            if (v is float || v is double || v is decimal)
            {
                double d = Convert.ToDouble(v, CultureInfo.InvariantCulture);
                if (double.IsNaN(d) || double.IsInfinity(d)) { sb.Append("null"); return; }
                // Integral doubles print without a trailing ".0" to match ConvertTo-Json.
                if (d == Math.Floor(d) && !double.IsInfinity(d) && Math.Abs(d) < 1e15)
                    sb.Append(((long)d).ToString(CultureInfo.InvariantCulture));
                else
                    sb.Append(d.ToString("R", CultureInfo.InvariantCulture));
                return;
            }
            if (v is sbyte || v is byte || v is short || v is ushort || v is int || v is uint || v is long || v is ulong)
            {
                sb.Append(Convert.ToString(v, CultureInfo.InvariantCulture));
                return;
            }
            if (v is IDictionary)
            {
                IDictionary dict = (IDictionary)v;
                sb.Append('{'); bool first = true;
                foreach (DictionaryEntry e in dict)
                {
                    if (!first) sb.Append(','); first = false;
                    WriteString(sb, Convert.ToString(e.Key, CultureInfo.InvariantCulture));
                    sb.Append(':'); WriteValue(sb, e.Value);
                }
                sb.Append('}'); return;
            }
            if (v is IEnumerable)
            {
                IEnumerable en = (IEnumerable)v;
                sb.Append('['); bool first = true;
                foreach (var item in en) { if (!first) sb.Append(','); first = false; WriteValue(sb, item); }
                sb.Append(']'); return;
            }
            // Fallback: stringify.
            WriteString(sb, Convert.ToString(v, CultureInfo.InvariantCulture));
        }

        private static void WriteObj(StringBuilder sb, JObj o)
        {
            sb.Append('{'); bool first = true;
            foreach (var kv in o)
            {
                if (!first) sb.Append(','); first = false;
                WriteString(sb, kv.Key); sb.Append(':'); WriteValue(sb, kv.Value);
            }
            sb.Append('}');
        }

        private static void WriteArr(StringBuilder sb, JArr a)
        {
            sb.Append('['); bool first = true;
            foreach (var item in a) { if (!first) sb.Append(','); first = false; WriteValue(sb, item); }
            sb.Append(']');
        }

        private static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\b': sb.Append("\\b"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        // ---- parser ---------------------------------------------------------
        public static object Parse(string text)
        {
            if (text == null) return null;
            int i = 0;
            object result = ParseValue(text, ref i);
            SkipWs(text, ref i);
            return result;
        }

        public static JObj ParseObject(string text)
        {
            var v = Parse(text);
            return v as JObj ?? new JObj();
        }

        private static void SkipWs(string s, ref int i)
        {
            while (i < s.Length)
            {
                char c = s[i];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') i++;
                else break;
            }
        }

        private static object ParseValue(string s, ref int i)
        {
            SkipWs(s, ref i);
            if (i >= s.Length) throw new FormatException("Unexpected end of JSON");
            char c = s[i];
            switch (c)
            {
                case '{': return ParseObj(s, ref i);
                case '[': return ParseArr(s, ref i);
                case '"': return ParseStr(s, ref i);
                case 't': Expect(s, ref i, "true"); return true;
                case 'f': Expect(s, ref i, "false"); return false;
                case 'n': Expect(s, ref i, "null"); return null;
                default: return ParseNum(s, ref i);
            }
        }

        private static void Expect(string s, ref int i, string word)
        {
            if (i + word.Length > s.Length || s.Substring(i, word.Length) != word)
                throw new FormatException("Invalid JSON literal at " + i);
            i += word.Length;
        }

        private static JObj ParseObj(string s, ref int i)
        {
            var o = new JObj();
            i++; // {
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return o; }
            while (true)
            {
                SkipWs(s, ref i);
                string key = ParseStr(s, ref i);
                SkipWs(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new FormatException("Expected ':' at " + i);
                i++;
                object val = ParseValue(s, ref i);
                o[key] = val;
                SkipWs(s, ref i);
                if (i >= s.Length) throw new FormatException("Unterminated object");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') { i++; break; }
                throw new FormatException("Expected ',' or '}' at " + i);
            }
            return o;
        }

        private static JArr ParseArr(string s, ref int i)
        {
            var a = new JArr();
            i++; // [
            SkipWs(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return a; }
            while (true)
            {
                object val = ParseValue(s, ref i);
                a.Add(val);
                SkipWs(s, ref i);
                if (i >= s.Length) throw new FormatException("Unterminated array");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == ']') { i++; break; }
                throw new FormatException("Expected ',' or ']' at " + i);
            }
            return a;
        }

        private static string ParseStr(string s, ref int i)
        {
            if (s[i] != '"') throw new FormatException("Expected string at " + i);
            i++;
            var sb = new StringBuilder();
            while (i < s.Length)
            {
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c == '\\')
                {
                    if (i >= s.Length) break;
                    char e = s[i++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (i + 4 > s.Length) throw new FormatException("Bad \\u escape");
                            int code = int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                            i += 4;
                            sb.Append((char)code);
                            break;
                        default: sb.Append(e); break;
                    }
                }
                else sb.Append(c);
            }
            throw new FormatException("Unterminated string");
        }

        private static object ParseNum(string s, ref int i)
        {
            int start = i;
            while (i < s.Length)
            {
                char c = s[i];
                if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') i++;
                else break;
            }
            string num = s.Substring(start, i - start);
            double d;
            if (double.TryParse(num, NumberStyles.Any, CultureInfo.InvariantCulture, out d)) return d;
            throw new FormatException("Invalid number '" + num + "' at " + start);
        }
    }
}
