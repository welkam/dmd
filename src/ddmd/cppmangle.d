/**
 * Compiler implementation of the $(LINK2 http://www.dlang.org, D programming language)
 *
 * Copyright: Copyright (c) 1999-2017 by Digital Mars, All Rights Reserved
 * Authors: Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/ddmd/cppmangle.d, _cppmangle.d)
 */

module ddmd.cppmangle;

// Online documentation: https://dlang.org/phobos/ddmd_cppmangle.html

import core.stdc.string;
import core.stdc.stdio;

import ddmd.arraytypes;
import ddmd.declaration;
import ddmd.dsymbol;
import ddmd.dtemplate;
import ddmd.errors;
import ddmd.expression;
import ddmd.func;
import ddmd.globals;
import ddmd.id;
import ddmd.mtype;
import ddmd.root.outbuffer;
import ddmd.root.rootobject;
import ddmd.target;
import ddmd.tokens;
import ddmd.typesem;
import ddmd.visitor;

/* Do mangling for C++ linkage.
 * Follows Itanium C++ ABI 1.86 section 5.1
 * http://refspecs.linux-foundation.org/cxxabi-1.86.html#mangling
 * which is where the grammar comments come from.
 */

extern (C++):

const(char)* toCppMangleItanium(Dsymbol s)
{
    //printf("toCppMangleItanium(%s)\n", s.toChars());
    OutBuffer buf;
    Target.prefixName(&buf, LINKcpp);
    scope CppMangleVisitor v = new CppMangleVisitor(&buf, s.loc);
    v.mangleOf(s);
    return buf.extractString();
}

const(char)* cppTypeInfoMangleItanium(Dsymbol s)
{
    //printf("cppTypeInfoMangle(%s)\n", s.toChars());
    OutBuffer buf;
    buf.writestring("_ZTI");    // "TI" means typeinfo structure
    scope CppMangleVisitor v = new CppMangleVisitor(&buf, s.loc);
    v.cpp_mangle_name(s, false);
    return buf.extractString();
}

private final class CppMangleVisitor : Visitor
{
    alias visit = super.visit;
    Objects components;         // array of components available for substitution
    OutBuffer* buf;             // append the mangling to buf[]
    bool is_top_level;          // true if ignore 'const' mangling attribute
    bool components_on;
    Loc loc;                    // location for use in error messages

  final:
    bool substitute(RootObject p)
    {
        //printf("substitute %s\n", p ? p.toChars() : null);
        auto i = find(p);
        if (i >= 0)
        {
            //printf("\tmatch\n");
            /* Sequence is S_, S0_, .., S9_, SA_, ..., SZ_, S10_, ...
             */
            buf.writeByte('S');
            if (i)
            {
                // Write <seq-id> to buf
                void write_seq_id(size_t i)
                {
                    if (i >= 36)
                    {
                        write_seq_id(i / 36);
                        i %= 36;
                    }
                    i += (i < 10) ? '0' : 'A' - 10;
                    buf.writeByte(cast(char)i);
                }

                write_seq_id(i - 1);
            }
            buf.writeByte('_');
            return true;
        }
        return false;
    }

    /******
     * See if `p` exists in components[]
     * Returns:
     *  index if found, -1 if not
     */
    int find(RootObject p)
    {
        //printf("find %p %d %s\n", p, p.dyncast(), p ? p.toChars() : null);
        if (components_on)
        {
            foreach (i, component; components)
            {
                if (p == component)
                    return cast(int)i;
            }
        }
        return -1;
    }

    /*********************
     * Append p to components[]
     */
    void append(RootObject p)
    {
        //printf("append %p %d %s\n", p, p.dyncast(), p ? p.toChars() : "null");
        if (components_on)
            components.push(p);
    }

    /******************************
     * Write the mangled representation of the template arguments.
     * Params:
     *  ti = the template instance
     */
    void template_args(TemplateInstance ti)
    {
        /* <template-args> ::= I <template-arg>+ E
         */
        if (!ti)                // could happen if std::basic_string is not a template
            return;
        buf.writeByte('I');
        bool is_var_arg = false;
        foreach (i, o; *ti.tiargs)
        {
            TemplateParameter tp = null;
            TemplateValueParameter tv = null;
            TemplateTupleParameter tt = null;
            if (!is_var_arg)
            {
                TemplateDeclaration td = ti.tempdecl.isTemplateDeclaration();
                assert(td);
                tp = (*td.parameters)[i];
                tv = tp.isTemplateValueParameter();
                tt = tp.isTemplateTupleParameter();
            }
            /*
             * <template-arg> ::= <type>               # type or template
             *                ::= X <expression> E     # expression
             *                ::= <expr-primary>       # simple expressions
             *                ::= I <template-arg>* E  # argument pack
             */
            if (tt)
            {
                buf.writeByte('I');     // argument pack
                is_var_arg = true;
                tp = null;
            }
            if (tv)
            {
                // <expr-primary> ::= L <type> <value number> E  # integer literal
                if (tv.valType.isintegral())
                {
                    Expression e = isExpression(o);
                    assert(e);
                    buf.writeByte('L');
                    tv.valType.accept(this);
                    if (tv.valType.isunsigned())
                    {
                        buf.printf("%llu", e.toUInteger());
                    }
                    else
                    {
                        sinteger_t val = e.toInteger();
                        if (val < 0)
                        {
                            val = -val;
                            buf.writeByte('n');
                        }
                        buf.printf("%lld", val);
                    }
                    buf.writeByte('E');
                }
                else
                {
                    ti.error("Internal Compiler Error: C++ %s template value parameter is not supported", tv.valType.toChars());
                    fatal();
                }
            }
            else if (!tp || tp.isTemplateTypeParameter())
            {
                Type t = isType(o);
                assert(t);
                t.accept(this);
            }
            else if (tp.isTemplateAliasParameter())
            {
                Dsymbol d = isDsymbol(o);
                Expression e = isExpression(o);
                if (!d && !e)
                {
                    ti.error("Internal Compiler Error: %s is unsupported parameter for C++ template: (%s)", o.toChars());
                    fatal();
                }
                if (d && d.isFuncDeclaration())
                {
                    bool is_nested = d.toParent() && !d.toParent().isModule() && (cast(TypeFunction)d.isFuncDeclaration().type).linkage == LINKcpp;
                    if (is_nested)
                        buf.writeByte('X');
                    buf.writeByte('L');
                    mangle_function(d.isFuncDeclaration());
                    buf.writeByte('E');
                    if (is_nested)
                        buf.writeByte('E');
                }
                else if (e && e.op == TOKvar && (cast(VarExp)e).var.isVarDeclaration())
                {
                    VarDeclaration vd = (cast(VarExp)e).var.isVarDeclaration();
                    buf.writeByte('L');
                    mangle_variable(vd, true);
                    buf.writeByte('E');
                }
                else if (d && d.isTemplateDeclaration() && d.isTemplateDeclaration().onemember)
                {
                    if (!substitute(d))
                    {
                        cpp_mangle_name(d, false);
                    }
                }
                else
                {
                    ti.error("Internal Compiler Error: %s is unsupported parameter for C++ template", o.toChars());
                    fatal();
                }
            }
            else
            {
                ti.error("Internal Compiler Error: C++ templates support only integral value, type parameters, alias templates and alias function parameters");
                fatal();
            }
        }
        if (is_var_arg)
        {
            buf.writeByte('E');
        }
        buf.writeByte('E');
    }


    void source_name(Dsymbol s)
    {
        //printf("source_name(%s)\n", s.toChars());
        if (TemplateInstance ti = s.isTemplateInstance())
        {
            if (!substitute(ti.tempdecl))
            {
                append(ti.tempdecl);
                const name = ti.tempdecl.toAlias().ident.toChars();
                buf.printf("%d%s", strlen(name), name);
            }
            template_args(ti);
        }
        else
        {
            const name = s.ident.toChars();
            buf.printf("%d%s", strlen(name), name);
        }
    }

    /********
     * Get qualifier for `s`, meaning the symbol
     * that s is in the symbol table of.
     * The module does not count as a qualifier, because C++
     * does not have modules.
     * Params:
     *  s = symbol that may have a qualifier
     * Returns:
     *  qualifier, null if none
     */
    Dsymbol getQualifier(Dsymbol s)
    {
        Dsymbol p = s.toParent();
        return (p && !p.isModule()) ? p : null;
    }

    void prefix_name(Dsymbol s)
    {
        //printf("prefix_name(%s)\n", s.toChars());
        if (!substitute(s))
        {
            Dsymbol p = s.toParent();
            if (p && p.isTemplateInstance())
            {
                s = p;
                if (find(p.isTemplateInstance().tempdecl) >= 0)
                {
                    p = null;
                }
                else
                {
                    p = p.toParent();
                }
            }
            if (p && !p.isModule())
            {
                if (p.ident == Id.std && is_initial_qualifier(p))
                    buf.writestring("St");
                else
                    prefix_name(p);
            }
            source_name(s);
            if (!(s.ident == Id.std && is_initial_qualifier(s)))
                /* Do this after the source_name() call to keep components[]
                 * in the right order.
                 * https://issues.dlang.org/show_bug.cgi?id=17947
                 */
                append(s);
        }
    }

    /* Is s the initial qualifier?
     */
    bool is_initial_qualifier(Dsymbol s)
    {
        Dsymbol p = s.toParent();
        if (p && p.isTemplateInstance())
        {
            if (find(p.isTemplateInstance().tempdecl) >= 0)
            {
                return true;
            }
            p = p.toParent();
        }
        return !p || p.isModule();
    }

    void cpp_mangle_name(Dsymbol s, bool qualified)
    {
        //printf("cpp_mangle_name(%s, %d)\n", s.toChars(), qualified);
        Dsymbol p = s.toParent();
        Dsymbol se = s;
        bool write_prefix = true;
        if (p && p.isTemplateInstance())
        {
            se = p;
            if (find(p.isTemplateInstance().tempdecl) >= 0)
                write_prefix = false;
            p = p.toParent();
        }
        if (p && !p.isModule())
        {
            /* The N..E is not required if:
             * 1. the parent is 'std'
             * 2. 'std' is the initial qualifier
             * 3. there is no CV-qualifier or a ref-qualifier for a member function
             * ABI 5.1.8
             */
            if (p.ident == Id.std && is_initial_qualifier(p) && !qualified)
            {
                TemplateInstance ti = se.isTemplateInstance();
                if (s.ident == Id.allocator)
                {
                    buf.writestring("Sa"); // "Sa" is short for ::std::allocator
                    template_args(ti);
                }
                else if (s.ident == Id.basic_string)
                {
                    components_on = false; // turn off substitutions
                    buf.writestring("Sb"); // "Sb" is short for ::std::basic_string
                    size_t off = buf.offset;
                    template_args(ti);
                    components_on = true;
                    // Replace ::std::basic_string < char, ::std::char_traits<char>, ::std::allocator<char> >
                    // with Ss
                    //printf("xx: '%.*s'\n", (int)(buf.offset - off), buf.data + off);
                    if (buf.offset - off >= 26 && memcmp(buf.data + off, "IcSt11char_traitsIcESaIcEE".ptr, 26) == 0)
                    {
                        buf.remove(off - 2, 28);
                        buf.insert(off - 2, "Ss");
                        return;
                    }
                    buf.setsize(off);
                    template_args(ti);
                }
                else if (s.ident == Id.basic_istream || s.ident == Id.basic_ostream || s.ident == Id.basic_iostream)
                {
                    /* Replace
                     * ::std::basic_istream<char,  std::char_traits<char> > with Si
                     * ::std::basic_ostream<char,  std::char_traits<char> > with So
                     * ::std::basic_iostream<char, std::char_traits<char> > with Sd
                     */
                    size_t off = buf.offset;
                    components_on = false; // turn off substitutions
                    template_args(ti);
                    components_on = true;
                    //printf("xx: '%.*s'\n", (int)(buf.offset - off), buf.data + off);
                    if (buf.offset - off >= 21 && memcmp(buf.data + off, "IcSt11char_traitsIcEE".ptr, 21) == 0)
                    {
                        buf.remove(off, 21);
                        char[2] mbuf;
                        mbuf[0] = 'S';
                        mbuf[1] = 'i';
                        if (s.ident == Id.basic_ostream)
                            mbuf[1] = 'o';
                        else if (s.ident == Id.basic_iostream)
                            mbuf[1] = 'd';
                        buf.insert(off, mbuf[]);
                        return;
                    }
                    buf.setsize(off);
                    buf.writestring("St");
                    source_name(se);
                }
                else
                {
                    buf.writestring("St");
                    source_name(se);
                }
            }
            else
            {
                buf.writeByte('N');
                if (write_prefix)
                    prefix_name(p);
                source_name(se);
                buf.writeByte('E');
            }
        }
        else
            source_name(se);
        append(s);
    }

    void CV_qualifiers(Type t)
    {
        // CV-qualifiers are 'r': restrict, 'V': volatile, 'K': const
        if (t.isConst())
            buf.writeByte('K');
    }

    void mangle_variable(VarDeclaration d, bool is_temp_arg_ref)
    {
        // fake mangling for fields to fix https://issues.dlang.org/show_bug.cgi?id=16525
        if (!(d.storage_class & (STCextern | STCfield | STCgshared)))
        {
            d.error("Internal Compiler Error: C++ static non- __gshared non-extern variables not supported");
            fatal();
        }
        Dsymbol p = d.toParent();
        if (p && !p.isModule()) //for example: char Namespace1::beta[6] should be mangled as "_ZN10Namespace14betaE"
        {
            buf.writestring("_ZN");
            prefix_name(p);
            source_name(d);
            buf.writeByte('E');
        }
        else //char beta[6] should mangle as "beta"
        {
            if (!is_temp_arg_ref)
            {
                buf.writestring(d.ident.toChars());
            }
            else
            {
                buf.writestring("_Z");
                source_name(d);
            }
        }
    }

    void mangle_function(FuncDeclaration d)
    {
        //printf("mangle_function(%s)\n", d.toChars());
        /*
         * <mangled-name> ::= _Z <encoding>
         * <encoding> ::= <function name> <bare-function-type>
         *            ::= <data name>
         *            ::= <special-name>
         */
        TypeFunction tf = cast(TypeFunction)d.type;
        buf.writestring("_Z");

        if (TemplateDeclaration ftd = getFuncTemplateDecl(d))
        {
            /* It's an instance of a function template
             */
            TemplateInstance ti = d.parent.isTemplateInstance();
            assert(ti);
            source_name(ti);
            this.is_top_level = true;
            tf.nextOf().accept(this);
            this.is_top_level = false;
        }
        else
        {
            Dsymbol p = d.toParent();
            if (p && !p.isModule() && tf.linkage == LINKcpp)
            {
                /* <nested-name> ::= N [<CV-qualifiers>] <prefix> <unqualified-name> E
                 *               ::= N [<CV-qualifiers>] <template-prefix> <template-args> E
                 */
                buf.writeByte('N');
                CV_qualifiers(d.type);

                /* <prefix> ::= <prefix> <unqualified-name>
                 *          ::= <template-prefix> <template-args>
                 *          ::= <template-param>
                 *          ::= # empty
                 *          ::= <substitution>
                 *          ::= <prefix> <data-member-prefix>
                 */
                prefix_name(p);

                // See ABI 5.1.8 Compression
                // Replace ::std::allocator with Sa
                if (buf.offset >= 17 && memcmp(buf.data, "_ZN3std9allocator".ptr, 17) == 0)
                {
                    buf.remove(3, 14);
                    buf.insert(3, "Sa");
                }
                // Replace ::std::basic_string with Sb
                if (buf.offset >= 21 && memcmp(buf.data, "_ZN3std12basic_string".ptr, 21) == 0)
                {
                    buf.remove(3, 18);
                    buf.insert(3, "Sb");
                }
                // Replace ::std with St
                if (buf.offset >= 7 && memcmp(buf.data, "_ZN3std".ptr, 7) == 0)
                {
                    buf.remove(3, 4);
                    buf.insert(3, "St");
                }
                if (buf.offset >= 8 && memcmp(buf.data, "_ZNK3std".ptr, 8) == 0)
                {
                    buf.remove(4, 4);
                    buf.insert(4, "St");
                }
                if (d.isDtorDeclaration())
                {
                    buf.writestring("D1");
                }
                else
                {
                    source_name(d);
                }
                buf.writeByte('E');
            }
            else
            {
                source_name(d);
            }
        }

        if (tf.linkage == LINKcpp) //Template args accept extern "C" symbols with special mangling
        {
            assert(tf.ty == Tfunction);
            mangleFunctionParameters(tf.parameters, tf.varargs);
        }
    }

    void mangleFunctionParameters(Parameters* parameters, int varargs)
    {
        int numparams = 0;

        int paramsCppMangleDg(size_t n, Parameter fparam)
        {
            Type t = fparam.type.merge2();
            if (fparam.storageClass & (STCout | STCref))
                t = t.referenceTo();
            else if (fparam.storageClass & STClazy)
            {
                // Mangle as delegate
                Type td = new TypeFunction(null, t, 0, LINKd);
                td = new TypeDelegate(td);
                t = merge(t);
            }
            if (t.ty == Tsarray)
            {
                // Static arrays in D are passed by value; no counterpart in C++
                t.error(loc, "Internal Compiler Error: unable to pass static array `%s` to extern(C++) function, use pointer instead",
                    t.toChars());
                fatal();
            }
            /* If it is a basic, enum or struct type,
             * then don't mark it const
             */
            this.is_top_level = true;
            if ((t.ty == Tenum || t.ty == Tstruct || t.ty == Tpointer || t.isTypeBasic()) && t.isConst())
                t.mutableOf().accept(this);
            else
                t.accept(this);
            this.is_top_level = false;
            ++numparams;
            return 0;
        }

        if (parameters)
            Parameter._foreach(parameters, &paramsCppMangleDg);
        if (varargs)
            buf.writeByte('z');
        else if (!numparams)
            buf.writeByte('v'); // encode (void) parameters
    }

public:
    extern (D) this(OutBuffer* buf, Loc loc)
    {
        this.buf = buf;
        this.loc = loc;
        this.components_on = true;
    }

    /*****
     * Entry point. Append mangling to buf[]
     * Params:
     *  s = symbol to mangle
     */
    void mangleOf(Dsymbol s)
    {
        if (VarDeclaration vd = s.isVarDeclaration())
        {
            mangle_variable(vd, false);
        }
        else if (FuncDeclaration fd = s.isFuncDeclaration())
        {
            mangle_function(fd);
        }
        else
        {
            assert(0);
        }
    }

    /****** The rest is type mangling ************/

    void error(Type t)
    {
        if (t.isImmutable() || t.isShared())
        {
            t.error(loc, "Internal Compiler Error: shared or immutable types can not be mapped to C++ `%s`", t.toChars());
        }
        else
        {
            t.error(loc, "Internal Compiler Error: type `%s` can not be mapped to C++\n", t.toChars());
        }
        fatal(); //Fatal, because this error should be handled in frontend
    }

    override void visit(Type t)
    {
        error(t);
    }

    /******
     * Write out 1 or 2 character basic type mangling.
     * Handle const and substitutions.
     * Params:
     *  t = type to mangle
     *  p = if not 0, then character prefix
     *  c = mangling character
     */
    void writeBasicType(Type t, char p, char c)
    {
        if (p || t.isConst())
        {
            if (substitute(t))
                return;
            else
                append(t);
        }
        CV_qualifiers(t);
        if (p)
            buf.writeByte(p);
        buf.writeByte(c);
    }

    override void visit(TypeBasic t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        /* <builtin-type>:
         * v        void
         * w        wchar_t
         * b        bool
         * c        char
         * a        signed char
         * h        unsigned char
         * s        short
         * t        unsigned short
         * i        int
         * j        unsigned int
         * l        long
         * m        unsigned long
         * x        long long, __int64
         * y        unsigned long long, __int64
         * n        __int128
         * o        unsigned __int128
         * f        float
         * d        double
         * e        long double, __float80
         * g        __float128
         * z        ellipsis
         * Dd       64 bit IEEE 754r decimal floating point
         * De       128 bit IEEE 754r decimal floating point
         * Df       32 bit IEEE 754r decimal floating point
         * Dh       16 bit IEEE 754r half-precision floating point
         * Di       char32_t
         * Ds       char16_t
         * u <source-name>  # vendor extended type
         */
        char c;
        char p = 0;
        switch (t.ty)
        {
            case Tvoid:                 c = 'v';        break;
            case Tint8:                 c = 'a';        break;
            case Tuns8:                 c = 'h';        break;
            case Tint16:                c = 's';        break;
            case Tuns16:                c = 't';        break;
            case Tint32:                c = 'i';        break;
            case Tuns32:                c = 'j';        break;
            case Tfloat32:              c = 'f';        break;
            case Tint64:
                c = (Target.c_longsize == 8 ? 'l' : 'x');
                break;
            case Tuns64:
                c = (Target.c_longsize == 8 ? 'm' : 'y');
                break;
            case Tint128:                c = 'n';       break;
            case Tuns128:                c = 'o';       break;
            case Tfloat64:               c = 'd';       break;
            case Tfloat80:               c = 'e';       break;
            case Tbool:                  c = 'b';       break;
            case Tchar:                  c = 'c';       break;
            case Twchar:                 c = 't';       break;  // unsigned short (perhaps use 'Ds' ?
            case Tdchar:                 c = 'w';       break;  // wchar_t (UTF-32) (perhaps use 'Di' ?
            case Timaginary32:  p = 'G'; c = 'f';       break;  // 'G' means imaginary
            case Timaginary64:  p = 'G'; c = 'd';       break;
            case Timaginary80:  p = 'G'; c = 'e';       break;
            case Tcomplex32:    p = 'C'; c = 'f';       break;  // 'C' means complex
            case Tcomplex64:    p = 'C'; c = 'd';       break;
            case Tcomplex80:    p = 'C'; c = 'e';       break;

            default:
                // Handle any target-specific basic types.
                if (auto tm = Target.cppTypeMangle(t))
                {
                    if (substitute(t))
                        return;
                    else
                        append(t);
                    CV_qualifiers(t);
                    buf.writestring(tm);
                    return;
                }
                return error(t);
        }
        writeBasicType(t, p, c);
    }

    override void visit(TypeVector t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        is_top_level = false;
        if (substitute(t))
            return;
        append(t);
        CV_qualifiers(t);

        // Handle any target-specific vector types.
        if (auto tm = Target.cppTypeMangle(t))
        {
            buf.writestring(tm);
        }
        else
        {
            assert(t.basetype && t.basetype.ty == Tsarray);
            assert((cast(TypeSArray)t.basetype).dim);
            version (none)
                buf.printf("Dv%llu_", (cast(TypeSArray *)t.basetype).dim.toInteger()); // -- Gnu ABI v.4
            else
                buf.writestring("U8__vector"); //-- Gnu ABI v.3
            t.basetype.nextOf().accept(this);
        }
    }

    override void visit(TypeSArray t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        is_top_level = false;
        if (!substitute(t))
            append(t);
        CV_qualifiers(t);
        buf.printf("A%llu_", t.dim ? t.dim.toInteger() : 0);
        t.next.accept(this);
    }

    override void visit(TypePointer t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        is_top_level = false;
        if (substitute(t))
            return;
        CV_qualifiers(t);
        buf.writeByte('P');
        t.next.accept(this);
        append(t);
    }

    override void visit(TypeReference t)
    {
        //printf("TypeReference %s\n", t.toChars());
        is_top_level = false;
        if (substitute(t))
            return;
        buf.writeByte('R');
        t.next.accept(this);
        append(t);
    }

    override void visit(TypeFunction t)
    {
        is_top_level = false;
        /*
         *  <function-type> ::= F [Y] <bare-function-type> E
         *  <bare-function-type> ::= <signature type>+
         *  # types are possible return type, then parameter types
         */
        /* ABI says:
            "The type of a non-static member function is considered to be different,
            for the purposes of substitution, from the type of a namespace-scope or
            static member function whose type appears similar. The types of two
            non-static member functions are considered to be different, for the
            purposes of substitution, if the functions are members of different
            classes. In other words, for the purposes of substitution, the class of
            which the function is a member is considered part of the type of
            function."

            BUG: Right now, types of functions are never merged, so our simplistic
            component matcher always finds them to be different.
            We should use Type.equals on these, and use different
            TypeFunctions for non-static member functions, and non-static
            member functions of different classes.
         */
        if (substitute(t))
            return;
        buf.writeByte('F');
        if (t.linkage == LINKc)
            buf.writeByte('Y');
        Type tn = t.next;
        if (t.isref)
            tn = tn.referenceTo();
        tn.accept(this);
        mangleFunctionParameters(t.parameters, t.varargs);
        buf.writeByte('E');
        append(t);
    }

    override void visit(TypeStruct t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        /* __c_long and __c_ulong get special mangling
         */
        const id = t.sym.ident;
        //printf("struct id = '%s'\n", id.toChars());
        if (id == Id.__c_long)
            return writeBasicType(t, 0, 'l');
        else if (id == Id.__c_ulong)
            return writeBasicType(t, 0, 'm');

        //printf("TypeStruct %s\n", t.toChars());
        is_top_level = false;
        if (substitute(t))
            return;
        CV_qualifiers(t);

        // Handle any target-specific struct types.
        if (auto tm = Target.cppTypeMangle(t))
        {
            buf.writestring(tm);
        }
        else
        {
            Dsymbol s = t.sym;
            Dsymbol p = s.toParent();
            if (p && p.isTemplateInstance())
            {
                 /* https://issues.dlang.org/show_bug.cgi?id=17947
                  * Substitute the template instance symbol, not the struct symbol
                  */
                if (substitute(p))
                    return;
            }
            if (!substitute(s))
            {
                cpp_mangle_name(s, t.isConst());
            }
        }
        if (t.isConst())
            append(t);
    }

    override void visit(TypeEnum t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        is_top_level = false;
        if (substitute(t))
            return;
        CV_qualifiers(t);
        if (!substitute(t.sym))
        {
            cpp_mangle_name(t.sym, t.isConst());
        }
        if (t.isConst())
            append(t);
    }

    override void visit(TypeClass t)
    {
        if (t.isImmutable() || t.isShared())
            return error(t);

        if (substitute(t))
            return;
        if (!is_top_level)
            CV_qualifiers(t);
        is_top_level = false;
        buf.writeByte('P');
        CV_qualifiers(t);
        if (!substitute(t.sym))
        {
            cpp_mangle_name(t.sym, t.isConst());
        }
        if (t.isConst())
            append(null);  // C++ would have an extra type here
        append(t);
    }
}