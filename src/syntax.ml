(* ficus abstract syntax definition + helper structures and functions *)

(*
   we represent all the symbols in the code by a pair of integers <a, b>.
   Initially, a=b and they both represent the textual name as it occurs in the code, e.g. "i".
   Later on, the type checker resolves the names and replaces b with
   some unique integer representing the particular object ("i") referenced in the particular
   context. For example:

   val i = 5
   val i = i + 1

   =>

   val i@100 : int = 5
   val i@101 : int = i@100 : int + 1

   (here i@100 means Id.Name(i, 100) and i@101 means Id.Name(i, 101), where i is index in the global
    table of symbolic names that corresponds to an abstract name "i", whereas 100 and 101
    are indices in the same table corresponding to the actually defined values.
    Internally the compiler uses unique names i@100 etc. to distinguish between values
    with the same name, but it uses the original names in error messages; it also uses the original name (i)
    to search for the symbol, i.e. Id.Name(f, f) can be matched with Id.Name(f, 12345) or Id.Name(f, 9876) or
    some other Id.Name(f, ...), depending on the current environment).

   There is a big global table of all symbols, so for each symbol we can retrieve its properties:
   the original name, inferred type, when and how it's defined.

   Sometimes we need a temporary value or a temporary function, i.e. when we do not have the original
   name. In this case we use some common prefix, e.g. "t" for intermediate results in complex expressions,
   "lambda" for anonymous functions etc. but we represent the id as Id.Temp(prefix, N). Such id is
   always displayed as prefix@@N, e.g. "t@@1000" or "lambda@@777", and it can only be matched with
   itself (prefix@@N). That is, it's really unique.
*)

module Id = struct
   type t = Name of int * int | Temp of int * int
   let compare a b =
      let a_idx = match (a) with Name(_, idx) -> idx | Temp(_, idx) -> idx in
      let b_idx = match (b) with Name(_, idx) -> idx | Temp(_, idx) -> idx in
      if a_idx < b_idx then -1 else if a_idx > b_idx then 1 else 0
end

type id_t = Id.t
let noid = Id.Name(0, 0)
let dummyid = Id.Name(1, 1)

(*
  Environment (Env.t) is the mapping from id_t to env_entry_t list. It's the key data structure used
  by the type checker.

  That is, for each id key Id.Name(i, i) (which corresponds to an abstract symbol <i>)
  we store a list of possible matches Id.Name(i, j) - the real defined symbols.
  When the key is Id.Temp(prefix, k), we can only have a single match Id.Temp(prefix, k).

  Why have a list of possible matches? Because:
   * in the nested scopes we can redefine a symbol from the outer scope
   * a defined value can be redefined later in the same block: val a = 5; val a = a + 1
     (we can set a certain compiler option in order to get a warning in such cases)
   * we can have overloaded functions, e.g. sin:float->float and sin:double->double
   * types and functions/values with the same name can co-exist without conflicts, e.g.
     string type and string:'t->string function.

  Note that we use purely-functional data structure (Map) to store the environment.
  Such immutable data structure let us forget about the neccesity to "undo" environment changes
  when we get back from the nested expression analysis, at the expense of slight loss in efficiency
  (however, the type checker is very inexpensive compiler stage, even in "-O0" compile mode)
*)
module Env = Map.Make(Id)
module IdSet = Set.Make(Id)

(*
   Scope of the definition

*)
type scope_t = ScBlock of int | ScFun of id_t | ScClass of id_t | ScInterface of id_t | ScModule of id_t | ScGlobal

type loc_t = { loc_fname: id_t; loc_line0: int; loc_pos0: int; loc_line1: int; loc_pos1: int }
let noloc = { loc_fname=noid; loc_line0=0; loc_pos0=0; loc_line1=0; loc_pos1=0 }

(* the primitive objects in the programs, literals, that represent themselves *)
type lit_t =
    | LitInt of Int64.t (* "int" (a signed integer that can be stored in CPU register,
                               64-bit on 64-bit platforms, 32-bit on 32-bit platforms) *)
    | LitSInt of int * Int64.t (* int8, int16, int32, int64 *)
    | LitUInt of int * Int64.t (* uint8, uint16, uint32, uint64.
      Ocaml does not provide unsigned 64-bit integer in its standard library
      (even though there is external UInt64 module). Let's use int64 to represent unsigned integers.
      (uint8, uint16 and uint32 will fit it easily, and operations on uint64 can be
      emulated using int64 ops (or even map to them 1:1) *)
    | LitFloat of int * float (* float, double, potentially half too *)
    | LitString of string (* UTF-8 string *)
    | LitChar of string (* a single character may require multiple "bytes", so we use a string for it *)
    | LitBool of bool
    | LitNil (* can be used as stub initializer for C pointers, interfaces, recursive variants, empty lists etc. *)
    | LitNone

(* type of an expression *)
type typ_t =
    | TypVar of typ_t option ref (* this is for type unification.
                        Initially most expressions are given TypVar (ref None) type,
                        and during type unification we
                        equalize types by redirecting those references to
                        other types (i.e. we use so-called destructive
                        type unification algorithm) *)
    | TypInt
    | TypSInt of int
    | TypUInt of int
    | TypFloat of int
    | TypString
    | TypChar
    | TypBool
    | TypVoid
    | TypFun of typ_t list * typ_t (* unlike some classical ML languages, we initially let
                                          functions to have multiple arguments, not just one *)
    | TypList of typ_t
    | TypTuple of typ_t list
    | TypRef of typ_t
    | TypOption of typ_t
    | TypArray of int * typ_t
    | TypRecord of ((id_t * typ_t * lit_t option) list * bool) ref
    | TypExn
    | TypErr (* a thrown exception; can be unified with any other type (except for declaration) *)
    | TypCPointer (* smart pointer to a C structure; we use it for file handlers, mutexes etc. *)
    | TypApp of typ_t list * id_t (* a generic type instance or a type alias (when typ_t list is empty) *)
    | TypDecl (* since declarations are also expressions, they should have some type;
                 and this is not "void" by the way *)
    | TypModule

let make_new_typ () = TypVar (ref (None: typ_t option))

type bin_op_t =
      OpAdd | OpSub | OpMul | OpDiv | OpMod | OpPow | OpShiftLeft | OpShiftRight
    | OpBitwiseAnd | OpLogicAnd | OpBitwiseOr | OpLogicOr | OpBitwiseXor
    | OpCompareEQ | OpCompareNE | OpCompareLT | OpCompareLE | OpCompareGT | OpCompareGE
    | OpCons | OpMem | OpSet

type un_op_t = OpPlus | OpNegate | OpBitwiseNot | OpLogicNot | OpMakeRef | OpDeref | OpThrow | OpExpand

type val_flag_t = ValArg | ValMutable
type func_flag_t = FunImpure | FunInC | FunInline | FunNoThrow | FunPure | FunStatic | FunConstr
type variant_flag_t = VariantRecursive | VariantSimpleLabel of int
type for_flag_t = ForParallel | ForMakeArray | ForMakeList | ForUnzip
type ctx_t = typ_t * loc_t

type exp_t =
    | ExpNop of ctx_t (* empty expression {} *)
    | ExpBreak of ctx_t
    | ExpContinue of ctx_t
    | ExpRange of exp_t option * exp_t option * exp_t option * ctx_t
    | ExpLit of lit_t * ctx_t
    | ExpIdent of id_t * ctx_t
    | ExpBinOp of bin_op_t * exp_t * exp_t * ctx_t
    | ExpUnOp of un_op_t * exp_t * ctx_t
    | ExpSeq of exp_t list * ctx_t
    | ExpMkTuple of exp_t list * ctx_t
    | ExpMkArray of exp_t list list * ctx_t
    | ExpMkRecord of exp_t * (id_t * exp_t) list * ctx_t
    | ExpUpdateRecord of exp_t * (id_t * exp_t) list * ctx_t
    | ExpCall of exp_t * exp_t list * ctx_t
    | ExpAt of exp_t * exp_t list * ctx_t
    | ExpIf of exp_t * exp_t * exp_t * ctx_t
    | ExpWhile of exp_t * exp_t * ctx_t
    | ExpDoWhile of exp_t * exp_t * ctx_t
    | ExpFor of (pat_t * exp_t) list * exp_t * for_flag_t list * ctx_t
    | ExpMap of ((pat_t * exp_t) list * exp_t option) list * exp_t * for_flag_t list * ctx_t
    | ExpTryCatch of exp_t * (pat_t list * exp_t) list * ctx_t
    | ExpMatch of exp_t * (pat_t list * exp_t) list * ctx_t
    | ExpCast of exp_t * typ_t * ctx_t
    | ExpTyped of exp_t * typ_t * ctx_t
    | ExpCCode of string * ctx_t
    | DefVal of pat_t * exp_t * val_flag_t list * loc_t
    | DefFun of deffun_t ref
    | DefExn of defexn_t ref
    | DefTyp of deftyp_t ref
    | DefVariant of defvariant_t ref
    | DefClass of defclass_t ref
    | DefInterface of definterface_t ref
    | DirImport of (id_t * id_t) list * loc_t
    | DirImportFrom of id_t * id_t list * loc_t
and pat_t =
    | PatAny of loc_t
    | PatLit of lit_t * loc_t
    | PatIdent of id_t * loc_t
    | PatTuple of pat_t list * loc_t
    | PatVariant of id_t * pat_t list * loc_t
    | PatRec of id_t option * (id_t * pat_t) list * loc_t
    | PatCons of pat_t * pat_t * loc_t
    | PatAs of pat_t * id_t * loc_t
    | PatTyped of pat_t * typ_t * loc_t
and defval_t = { dv_name: id_t; dv_typ: typ_t; dv_flags: val_flag_t list; dv_scope: scope_t list; dv_loc: loc_t }
and deffun_t = { df_name: id_t; df_templ_args: id_t list; df_args: pat_t list; df_typ: typ_t;
                 df_body: exp_t; df_flags: func_flag_t list; df_scope: scope_t list; df_loc: loc_t;
                 mutable df_templ_inst: id_t list }
and defexn_t = { dexn_name: id_t; dexn_typ: typ_t; dexn_scope: scope_t list; dexn_loc: loc_t }
and deftyp_t = { dt_name: id_t; dt_templ_args: id_t list;
                  dt_typ: typ_t; dt_scope: scope_t list; dt_finalized: bool; dt_loc: loc_t }
and defvariant_t = { dvar_name: id_t; dvar_templ_args: id_t list; dvar_typ: typ_t;
                     dvar_flags: variant_flag_t list; dvar_members: (id_t * typ_t) list;
                     dvar_constr: id_t list; mutable dvar_templ_inst: id_t list;
                     dvar_scope: scope_t list; dvar_loc: loc_t }
and defclass_t = { dcl_name: id_t; dcl_templ_args: id_t list; dcl_ifaces: id_t list; dcl_args: pat_t list;
                   dcl_members: exp_t list; mutable dcl_templ_inst: id_t list; dcl_scope: scope_t list; dcl_loc: loc_t }
and definterface_t = { di_name: id_t; di_base: id_t; di_members: exp_t list; di_scope: scope_t list; di_loc: loc_t }

type env_entry_t = EnvId of id_t | EnvTyp of typ_t
type env_t = env_entry_t list Env.t

type defmodule_t = { dm_name: id_t; dm_filename: string; mutable dm_defs: exp_t list;
                    mutable dm_deps: id_t list; mutable dm_env: env_t;
                    mutable dm_parsed: bool }

type id_info_t =
    | IdNone | IdText of string | IdVal of defval_t | IdFun of deffun_t ref
    | IdExn of defexn_t ref | IdTyp of deftyp_t ref | IdVariant of defvariant_t ref
    | IdClass of defclass_t ref | IdInterface of definterface_t ref | IdModule of defmodule_t ref

let all_nids = ref 0
let all_ids : id_info_t array ref = ref [||]
let all_strings: (string, int) Hashtbl.t = Hashtbl.create 1000
let all_modules: (string, id_t) Hashtbl.t = Hashtbl.create 100
let sorted_modules: id_t list ref = ref []

let sprintf = Printf.sprintf
let printf = Printf.printf

let new_id_idx() =
    let _ = if (Array.length !all_ids) <= !all_nids then
        let delta_nids = max !all_nids 128 in
        let new_ids = Array.make delta_nids IdNone in
        all_ids := Array.append !all_ids new_ids
    else () in
    let i = !all_nids in
    (all_nids := !all_nids + 1; i)

let dump_id i = match i with Id.Name(i, j) -> (sprintf "Id.Name(%d, %d)" i j)
                | Id.Temp(i, j) -> (sprintf "Id.Temp(%d, %d)" i j)
let id2idx i = match i with Id.Name(_, i_real) -> i_real | Id.Temp(_, i_real) -> i_real
let id2str_ i pp =
    let (tempid, prefix, suffix) = match i with Id.Name(i_name, i_real) -> (false, i_name, i_real)
                            | Id.Temp(i_prefix, i_real) -> (true, i_prefix, i_real) in
    let s = (match (!all_ids).(prefix) with
        | IdText(s) -> s
        | _ -> failwith (sprintf
            "The first element of id=%s does not represent a string\n" (dump_id i))) in
    if tempid then (sprintf "%s@@%d" s suffix) else if pp || prefix = suffix then s else (sprintf "%s@%d" s suffix)

let id2str i = id2str_ i false
let pp_id2str i = id2str_ i true

let id_info i = (!all_ids).(id2idx i)

let get_id_ s =
    let idx =
    (match Hashtbl.find_all all_strings s with
    | x :: _ -> x
    | _ -> let i = new_id_idx() in
            (Hashtbl.add all_strings s i;
            (!all_ids).(i) <- IdText(s);
            i)) in idx

let get_id s =
    let i = get_id_ s in Id.Name(i, i)

let get_temp_id s =
    let i_name = get_id_ s in
    let i_real = new_id_idx() in
    Id.Temp(i_name, i_real)

let dup_id old_id =
    let k = new_id_idx() in
    match old_id with
    | Id.Name(i, j) -> Id.Name(i, k)
    | Id.Temp(i, j) -> Id.Temp(i, k)

let get_orig_id i =
    match i with
    | Id.Name(i, j) -> Id.Name(i, i)
    | Id.Temp(_, _) -> i

let good_variant_name s =
    let c0 = String.get s 0 in
    ('A' <= c0 && c0 <= 'Z') || (String.contains s '.')

let set_id_entry i n =
    let idx = id2idx i in (!all_ids).(idx) <- n

let module_loc mname = { loc_fname=mname; loc_line0=1; loc_pos0=1; loc_line1=1; loc_pos1=1 }

let get_exp_ctx e = match e with
    | ExpNop(c) -> c
    | ExpBreak(c) -> c
    | ExpContinue(c) -> c
    | ExpRange(_, _, _, c) -> c
    | ExpLit(_, c) -> c
    | ExpIdent(_, c) -> c
    | ExpBinOp(_, _, _, c) -> c
    | ExpUnOp(_, _, c) -> c
    | ExpSeq(_, c) -> c
    | ExpMkTuple(_, c) -> c
    | ExpMkRecord(_, _, c) -> c
    | ExpMkArray(_, c) -> c
    | ExpUpdateRecord(_, _, c) -> c
    | ExpCall(_, _, c) -> c
    | ExpAt(_, _, c) -> c
    | ExpIf(_, _, _, c) -> c
    | ExpWhile(_, _, c) -> c
    | ExpDoWhile(_, _, c) -> c
    | ExpFor(_, _, _, c) -> c
    | ExpMap(_, _, _, c) -> c
    | ExpTryCatch(_, _, c) -> c
    | ExpMatch(_, _, c) -> c
    | ExpCast(_, _, c) -> c
    | ExpTyped(_, _, c) -> c
    | ExpCCode(_, c) -> c
    | DefVal(_, _, _, dv_loc) -> (TypDecl, dv_loc)
    | DefFun {contents = { df_loc }} -> (TypDecl, df_loc)
    | DefExn {contents = { dexn_loc }} -> (TypDecl, dexn_loc)
    | DefTyp {contents = { dt_loc }} -> (TypDecl, dt_loc)
    | DefVariant {contents = { dvar_loc }} -> (TypDecl, dvar_loc)
    | DefClass {contents = { dcl_loc }} -> (TypDecl, dcl_loc)
    | DefInterface {contents = { di_loc }} -> (TypDecl, di_loc)
    | DirImport(_, l) -> (TypDecl, l)
    | DirImportFrom(_, _, l) -> (TypDecl, l)

let get_exp_typ e = let (t, l) = (get_exp_ctx e) in t
let get_exp_loc e = let (t, l) = (get_exp_ctx e) in l

let get_pat_loc p = match p with
    | PatAny l -> l
    | PatLit(_, l) -> l
    | PatIdent(_, l) -> l
    | PatTuple(_, l) -> l
    | PatVariant(_, _, l) -> l
    | PatRec(_, _, l) -> l
    | PatCons(_, _, l) -> l
    | PatAs(_, _, l) -> l
    | PatTyped(_, _, l) -> l

let get_module m =
    match id_info m with
    | IdModule minfo -> minfo
    | _ -> failwith (sprintf "internal error in process_all: %s is not a module" (pp_id2str m))

let find_module mname_id mfname =
    try get_module (Hashtbl.find all_modules mfname) with
    Not_found ->
        let m_fresh_id = dup_id mname_id in
        let newmodule = ref { dm_name=m_fresh_id; dm_filename=mfname; dm_defs=[];
                              dm_deps=[]; dm_env=Env.empty; dm_parsed=false } in
        set_id_entry m_fresh_id (IdModule newmodule);
        Hashtbl.add all_modules mfname m_fresh_id;
        newmodule

let block_scope_idx = ref (-1)
let new_block_scope () =
    block_scope_idx := !block_scope_idx + 1;
    ScBlock !block_scope_idx

let get_scope id_info = match id_info with
    | IdNone -> ScGlobal :: []
    | IdText _ -> ScGlobal :: []
    | IdVal {dv_scope} -> dv_scope
    | IdFun {contents = {df_scope}} -> df_scope
    | IdExn {contents = {dexn_scope}} -> dexn_scope
    | IdTyp {contents = {dt_scope}} -> dt_scope
    | IdVariant {contents = {dvar_scope}} -> dvar_scope
    | IdClass {contents = {dcl_scope}} -> dcl_scope
    | IdInterface {contents = {di_scope}} -> di_scope
    | IdModule _ -> ScGlobal :: []

let get_loc id_info = match id_info with
    | IdNone | IdText _ | IdModule _ -> noloc
    | IdVal {dv_loc} -> dv_loc
    | IdFun {contents = {df_loc}} -> df_loc
    | IdExn {contents = {dexn_loc}} -> dexn_loc
    | IdTyp {contents = {dt_loc}} -> dt_loc
    | IdVariant {contents = {dvar_loc}} -> dvar_loc
    | IdClass {contents = {dcl_loc}} -> dcl_loc
    | IdInterface {contents = {di_loc}} -> di_loc

(* used by the parser *)
exception SyntaxError of string*Lexing.position*Lexing.position
let loc2str loc = sprintf "%s: %d" (pp_id2str loc.loc_fname) loc.loc_line0

(* used by the type checker *)
let get_lit_typ l = match l with
    | LitInt(_) -> TypInt
    | LitSInt(b, _) -> TypSInt(b)
    | LitUInt(b, _) -> TypUInt(b)
    | LitFloat(b, _) -> TypFloat(b)
    | LitString(_) -> TypString
    | LitChar(_) -> TypChar
    | LitBool(_) -> TypBool
    | LitNil -> TypVar(ref None) (* in the case of NIL ([]) we cannot infere the type;
                                    we postpone this step *)
    | LitNone -> TypOption(TypVar(ref None)) (* same *)

let binop_to_string bop = match bop with
    | OpAdd -> "+"
    | OpSub -> "-"
    | OpMul -> "*"
    | OpDiv -> "/"
    | OpMod -> "%"
    | OpPow -> "**"
    | OpShiftLeft -> "<<"
    | OpShiftRight -> ">>"
    | OpBitwiseAnd -> "&"
    | OpLogicAnd -> "&&"
    | OpBitwiseOr -> "|"
    | OpLogicOr -> "||"
    | OpBitwiseXor -> "^"
    | OpCompareEQ -> "=="
    | OpCompareNE -> "!="
    | OpCompareLT -> "<"
    | OpCompareLE -> "<="
    | OpCompareGT -> ">"
    | OpCompareGE -> ">="
    | OpCons -> "::"
    | OpMem -> "."
    | OpSet -> "="

let unop_to_string uop = match uop with
    | OpPlus -> "+"
    | OpNegate -> "-"
    | OpBitwiseNot -> "~"
    | OpLogicNot -> "!"
    | OpMakeRef -> "ref"
    | OpDeref -> "*"
    | OpThrow -> "throw"
    | OpExpand -> "\\"

let fname_op_add = get_id "__add__"
let fname_op_sub = get_id "__sub__"
let fname_op_mul = get_id "__mul__"
let fname_op_div = get_id "__div__"
let fname_op_mod = get_id "__mod__"
let fname_op_pow = get_id "__pow__"
let fname_op_shl = get_id "__shl__"
let fname_op_shr = get_id "__shr__"
let fname_op_bit_and = get_id "__bit_and__"
let fname_op_bit_or = get_id "__bit_or__"
let fname_op_bit_xor = get_id "__bit_xor__"
let fname_op_eq = get_id "__eq__"
let fname_op_ne = get_id "__ne__"
let fname_op_lt = get_id "__lt__"
let fname_op_gt = get_id "__gt__"
let fname_op_le = get_id "__le__"
let fname_op_ge = get_id "__ge__"

let fname_op_plus = get_id "__plus__"
let fname_op_negate = get_id "__negate__"
let fname_op_bit_not = get_id "__bit_not__"

let fname_to_int = get_id "int"
let fname_to_uint8 = get_id "uint8"
let fname_to_int8 = get_id "int8"
let fname_to_uint16 = get_id "uint16"
let fname_to_int16 = get_id "int16"
let fname_to_uint32 = get_id "uint32"
let fname_to_int32 = get_id "int32"
let fname_to_uint64 = get_id "uint64"
let fname_to_int64 = get_id "int64"
let fname_to_float = get_id "float"
let fname_to_double = get_id "double"
let fname_to_bool = get_id "bool"
let fname_to_string = get_id "string"

let get_binop_fname bop =
    match bop with
    | OpAdd -> fname_op_add
    | OpSub -> fname_op_sub
    | OpMul -> fname_op_mul
    | OpDiv -> fname_op_div
    | OpMod -> fname_op_mod
    | OpPow -> fname_op_pow
    | OpShiftLeft -> fname_op_shl
    | OpShiftRight -> fname_op_shr
    | OpBitwiseAnd -> fname_op_bit_and
    | OpBitwiseOr -> fname_op_bit_or
    | OpBitwiseXor -> fname_op_bit_xor
    | OpCompareEQ -> fname_op_eq
    | OpCompareNE -> fname_op_ne
    | OpCompareLT -> fname_op_lt
    | OpCompareLE -> fname_op_le
    | OpCompareGT -> fname_op_gt
    | OpCompareGE -> fname_op_ge
    | OpLogicAnd | OpLogicOr | OpCons | OpMem | OpSet ->
        failwith (sprintf "for binary operation \"%s\" there is no corresponding function" (binop_to_string bop))

let get_unop_fname uop =
    match uop with
    | OpPlus -> fname_op_plus
    | OpNegate -> fname_op_negate
    | OpBitwiseNot -> fname_op_bit_not
    | OpLogicNot | OpMakeRef | OpDeref | OpThrow | OpExpand ->
        failwith (sprintf "for unary operation \"%s\" there is no corresponding function" (unop_to_string uop))
