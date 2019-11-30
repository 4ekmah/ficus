(*
    K-normal form (or K-form in short) definition.
    This is a greatly extended variant of K-normal form in min-caml:
    https://github.com/esumii/min-caml.

    Similarly to ficus AST, which is defined in ast.ml,
    K-form is an hierarchical (tree-like) representation of
    the compiled code. However, it's much simpler and more
    suitable for intermediate optimizations and then for
    translation to some even lower-level representation, e.g. C code.

    In particular:

    * all the symbols in K-form are resolved and unique, e.g:
        fun foo(i: int) { val i = i+1; val i = i*2; for(i<-0:i) println(i) }
      is transformed to something like
        fun foo@999(i@1000: int): int {
          val i@1001: int = i@1000+1; val i@1002: int = i@1001*2
          for ((i@1003:int) <- 0:i@1002) println@56<int->void>(i@1003)
        }
    * all the symbols have known type. If it cannot be figured out,
      type checker or the k-form generator (see k_norm.ml) report compile error.
    * at once, all the types (typ_t) are converted to k-types (ktyp_t), i.e.
      all indirections are eliminated, instances of generic types
      (TypApp(<args...>, <some_generic_type_id>)) are replaced with concrete instances
      (KTypName(<instance_type_id>)) or even actual types where applicable.
    * all complex expressions are broken down into sequences of basic operations
      with intermediate results stored in temporary values.
    * pattern matching is converted into a sequences of nested if-expressions
    * import directives are removed; we've already resolved all the symbols
    * generic types and functions are removed. Their instances, generated
      by type checker, are retained though.
    * ...
*)
open Ast

(* it looks like OCaml generates some default compare operation for the types,
   so we do not have to define it explicitly *)
module Atom = struct
    type t = Id of id_t | Lit of lit_t
end

type atom_t = Atom.t

module Domain = struct
    type t = Elem of atom_t | Fast of atom_t | Range of atom_t * atom_t * atom_t
end

type dom_t = Domain.t

type intrin_t =
    | IntrinPopExn
    | IntrinMkRef
    | IntrinVariantTag
    | IntrinVariantCase
    | IntrinGetShape
    | IntrinListHead
    | IntrinListTail

type ktyp_t =
    | KTypInt
    | KTypSInt of int
    | KTypUInt of int
    | KTypFloat of int
    | KTypVoid
    | KTypNil
    | KTypBool
    | KTypChar
    | KTypString
    | KTypCPointer
    | KTypFun of ktyp_t list * ktyp_t
    | KTypTuple of ktyp_t list
    | KTypRecord of id_t * (id_t * ktyp_t) list
    | KTypName of id_t
    | KTypArray of int * ktyp_t
    | KTypList of ktyp_t
    | KTypRef of ktyp_t
    | KTypExn
    | KTypErr
    | KTypModule
and kctx_t = ktyp_t * loc_t
and kexp_t =
    | KExpNop of loc_t
    | KExpBreak of loc_t
    | KExpContinue of loc_t
    | KExpAtom of atom_t * kctx_t
    | KExpBinOp of binop_t * atom_t * atom_t * kctx_t
    | KExpUnOp of unop_t * atom_t * kctx_t
    | KExpIntrin of intrin_t * atom_t list * kctx_t
    | KExpSeq of kexp_t list * kctx_t
    | KExpIf of kexp_t * kexp_t * kexp_t * kctx_t
    | KExpCall of id_t * atom_t list * kctx_t
    | KExpMkTuple of atom_t list * kctx_t
    | KExpMkRecord of atom_t list * kctx_t
    | KExpMkArray of int list * atom_t list * kctx_t
    | KExpAt of atom_t * dom_t list * kctx_t
    | KExpMem of id_t * int * kctx_t
    | KExpDeref of id_t * kctx_t
    | KExpAssign of id_t * kexp_t * loc_t
    | KExpMatch of ((kexp_t list) * kexp_t) list * kctx_t
    | KExpTryCatch of kexp_t * kexp_t * kctx_t
    | KExpThrow of id_t * loc_t
    | KExpCast of atom_t * ktyp_t * loc_t
    | KExpMap of (kexp_t list * (id_t * dom_t) list) list * kexp_t * for_flag_t list * kctx_t
    | KExpFor of (id_t * dom_t) list * kexp_t * for_flag_t list * loc_t
    | KExpWhile of kexp_t * kexp_t * loc_t
    | KExpDoWhile of kexp_t * kexp_t * loc_t
    | KExpCCode of string * kctx_t
    | KDefVal of id_t * kexp_t * loc_t
    | KDefFun of kdeffun_t ref
    | KDefExn of kdefexn_t ref
    | KDefVariant of kdefvariant_t ref
and kdefval_t = { kv_name: id_t; kv_typ: ktyp_t; kv_flags: val_flag_t list; kv_scope: scope_t list; kv_loc: loc_t }
and kdeffun_t = { kf_name: id_t; kf_typ: ktyp_t; kf_args: id_t list; kf_body: kexp_t;
                  kf_flags: fun_flag_t list; kf_scope: scope_t list; kf_loc: loc_t }
and kdefexn_t = { ke_name: id_t; ke_typ: ktyp_t; ke_scope: scope_t list; ke_loc: loc_t }
and kdefvariant_t = { kvar_name: id_t; kvar_cases: (id_t * ktyp_t) list; kvar_constr: id_t list;
                      kvar_flags: variant_flag_t list; kvar_scope: scope_t list; kvar_loc: loc_t }

type kinfo_t =
    | KNone | KText of string | KVal of kdefval_t | KFun of kdeffun_t ref
    | KExn of kdefexn_t ref | KVariant of kdefvariant_t ref

let all_idks = dynvec_create KNone

let sprintf = Printf.sprintf
let printf = Printf.printf

let builtin_exn_NoMatchError = ref noid
let builtin_exn_IndexError = ref noid

let new_idk_idx() =
    let new_idx = dynvec_push all_ids in
    let new_kidx = dynvec_push all_idks in
    if new_idx = new_kidx then new_idx else
        failwith "internal error: unsynchronized outputs from new_id_idx() and new_idk_idx()"

let kinfo i = dynvec_get all_idks (id2idx i)

let gen_temp_idk s =
    let i_name = get_id_prefix s in
    let i_real = new_idk_idx() in
    Id.Temp(i_name, i_real)

let dup_idk old_id =
    let k = new_idk_idx() in
    match old_id with
    | Id.Name(i) -> Id.Val(i, k)
    | Id.Val(i, j) -> Id.Val(i, k)
    | Id.Temp(i, j) -> Id.Temp(i, k)

let set_idk_entry i n =
    let idx = id2idx i in dynvec_set all_idks idx n

let init_all_idks () =
    dynvec_init all_idks all_ids.dynvec_count

let get_kexp_ctx e = match e with
    | KExpNop(l) -> (KTypVoid, l)
    | KExpBreak(l) -> (KTypVoid, l)
    | KExpContinue(l) -> (KTypVoid, l)
    | KExpAtom(_, c) -> c
    | KExpBinOp(_, _, _, c) -> c
    | KExpUnOp(_, _, c) -> c
    | KExpIntrin(_, _, c) -> c
    | KExpSeq(_, c) -> c
    | KExpIf(_, _, _, c) -> c
    | KExpCall(_, _, c) -> c
    | KExpMkTuple(_, c) -> c
    | KExpMkRecord(_, c) -> c
    | KExpMkArray(_, _, c) -> c
    | KExpAt(_, _, c) -> c
    | KExpMem(_, _, c) -> c
    | KExpDeref(_, c) -> c
    | KExpAssign(_, _, l) -> (KTypVoid, l)
    | KExpMatch(_, c) -> c
    | KExpTryCatch(_, _, c) -> c
    | KExpThrow(_, l) -> (KTypErr, l)
    | KExpCast(_, t, l) -> (t, l)
    | KExpMap(_, _, _, c) -> c
    | KExpFor(_, _, _, l) -> (KTypVoid, l)
    | KExpWhile(_, _, l) -> (KTypVoid, l)
    | KExpDoWhile(_, _, l) -> (KTypVoid, l)
    | KExpCCode(_, c) -> c
    | KDefVal (_, _, l) -> (KTypVoid, l)
    | KDefFun {contents={kf_loc}} -> (KTypVoid, kf_loc)
    | KDefExn {contents={ke_loc}} -> (KTypVoid, ke_loc)
    | KDefVariant {contents={kvar_loc}} -> (KTypVoid, kvar_loc)

let get_kexp_typ e = let (t, l) = (get_kexp_ctx e) in t
let get_kexp_loc e = let (t, l) = (get_kexp_ctx e) in l

let get_kscope info =
    match info with
    | KNone -> ScGlobal :: []
    | KText _ -> ScGlobal :: []
    | KVal {kv_scope} -> kv_scope
    | KFun {contents = {kf_scope}} -> kf_scope
    | KExn {contents = {ke_scope}} -> ke_scope
    | KVariant {contents = {kvar_scope}} -> kvar_scope

let get_kinfo_loc info =
    match info with
    | KNone | KText _ -> noloc
    | KVal {kv_loc} -> kv_loc
    | KFun {contents = {kf_loc}} -> kf_loc
    | KExn {contents = {ke_loc}} -> ke_loc
    | KVariant {contents = {kvar_loc}} -> kvar_loc

let get_id_loc i = get_kinfo_loc (kinfo i)

let check_kinfo info i loc =
    match info with
    | KNone -> raise_compile_err loc (sprintf "attempt to request type of non-existing symbol '%s'" (id2str i))
    | KText s -> raise_compile_err loc (sprintf "attempt to request type of symbol '%s'" s)
    | _ -> ()

let get_kinfo_typ info i loc =
    check_kinfo info i loc;
    match info with
    | KNone -> KTypNil
    | KText _ -> KTypNil
    | KVal {kv_typ} -> kv_typ
    | KFun {contents = {kf_typ}} -> kf_typ
    | KExn {contents = {ke_typ}} -> ke_typ
    | KVariant {contents = {kvar_name}} -> KTypName(kvar_name)

let get_idk_typ i loc = get_kinfo_typ (kinfo i) i loc

(* used by the type checker *)
let get_lit_ktyp l = match l with
    | LitInt(_) -> KTypInt
    | LitSInt(b, _) -> KTypSInt(b)
    | LitUInt(b, _) -> KTypUInt(b)
    | LitFloat(b, _) -> KTypFloat(b)
    | LitString(_) -> KTypString
    | LitChar(_) -> KTypChar
    | LitBool(_) -> KTypBool
    | LitNil -> KTypNil

let get_atom_ktyp a loc =
    match a with
    | Atom.Id i -> get_idk_typ i loc
    | Atom.Lit l -> get_lit_ktyp l

let intrin2str iop = match iop with
    | IntrinPopExn -> "INTRIN_POP_EXN"
    | IntrinMkRef -> "INTRIN_MK_REF"
    | IntrinVariantTag -> "INTRIN_VARIANT_TAG"
    | IntrinVariantCase -> "INTRIN_VARIANT_CASE"
    | IntrinGetShape -> "INTRIN_GET_SHAPE"
    | IntrinListHead -> "INTRIN_LIST_HD"
    | IntrinListTail -> "INTRIN_LIST_TL"

let create_defval n t flags e_opt code sc loc =
    let dv = { kv_name=n; kv_typ=t; kv_flags=flags; kv_scope=sc; kv_loc=loc } in
    match t with
    | KTypVoid -> raise_compile_err loc "values of `void` type are not allowed"
    | _ -> ();
    set_idk_entry n (KVal dv);
    match e_opt with
    | Some(e) -> KDefVal(n, e, loc) :: code
    | _ -> code

let get_code_loc code default_loc =
    loclist2loc (List.map get_kexp_loc code) default_loc

let code2kexp code loc =
    match code with
    | [] -> KExpNop(loc)
    | e :: [] -> e
    | _ ->
        let t = get_kexp_typ (Utils.last_elem code) in
        let final_loc = get_code_loc code loc in
        KExpSeq(code, (t, final_loc))

let filter_out_nops code =
    List.filter (fun e -> match e with
        | KExpNop _ -> false
        | _ -> true) code

let rcode2kexp code loc = match (filter_out_nops code) with
    | [] -> KExpNop(loc)
    | e :: [] -> e
    | e :: rest ->
        let t = get_kexp_typ e in
        let final_loc = get_code_loc code loc in
        KExpSeq((List.rev code), (t, final_loc))

let kexp2code e =
    match e with
    | KExpNop _ -> []
    | KExpSeq(elist, _) -> elist
    | _ -> e :: []

(* walk through a K-normalized syntax tree and produce another tree *)

type k_callb_t =
{
    kcb_typ: (ktyp_t -> k_callb_t -> ktyp_t) option;
    kcb_exp: (kexp_t -> k_callb_t -> kexp_t) option;
    kcb_atom: (atom_t -> k_callb_t -> atom_t) option;
}

let rec check_n_walk_ktyp t callb =
    match callb.kcb_typ with
    | Some(f) -> f t callb
    | _ -> walk_ktyp t callb

and check_n_walk_kexp e callb =
    match callb.kcb_exp with
    | Some(f) -> f e callb
    | _ -> walk_kexp e callb

and check_n_walk_atom a callb =
    match callb.kcb_atom with
    | Some(f) -> f a callb
    | _ -> a
and check_n_walk_al al callb =
    List.map (fun a -> check_n_walk_atom a callb) al

and check_n_walk_dom d callb =
    match d with
    | Domain.Elem a -> Domain.Elem (check_n_walk_atom a callb)
    | Domain.Fast a -> Domain.Fast (check_n_walk_atom a callb)
    | Domain.Range (a, b, c) ->
        Domain.Range ((check_n_walk_atom a callb),
                      (check_n_walk_atom b callb),
                      (check_n_walk_atom c callb))

and walk_ktyp t callb =
    let walk_ktyp_ t = check_n_walk_ktyp t callb in
    let walk_ktl_ tl = List.map walk_ktyp_ tl in
    let walk_id_ k =
        match callb.kcb_atom with
        | Some(f) ->
            (match f (Atom.Id k) callb with
            | Atom.Id k -> k
            | _ -> failwith "internal error: inside walk_id the callback returned a literal, not id, which is unexpected.")
        | _ -> k in
    (match t with
    | KTypInt | KTypSInt _ | KTypUInt _ | KTypFloat _
    | KTypVoid | KTypNil | KTypBool
    | KTypChar | KTypString | KTypCPointer
    | KTypExn | KTypErr | KTypModule -> t
    | KTypFun (args, rt) -> KTypFun((walk_ktl_ args), (walk_ktyp_ rt))
    | KTypTuple elems -> KTypTuple(walk_ktl_ elems)
    | KTypRecord (rn, relems) ->
            KTypRecord((walk_id_ rn),
                (List.map (fun (ni, ti) -> ((walk_id_ ni), (walk_ktyp_ ti))) relems))
    | KTypName k -> KTypName(walk_id_ k)
    | KTypArray (d, t) -> KTypArray(d, (walk_ktyp_ t))
    | KTypList t -> KTypList(walk_ktyp_ t)
    | KTypRef t -> KTypRef(walk_ktyp_ t))

and walk_kexp e callb =
    let walk_atom_ a = check_n_walk_atom a callb in
    let walk_al_ al = List.map walk_atom_ al in
    let walk_ktyp_ t = check_n_walk_ktyp t callb in
    let walk_id_ k =
        match callb.kcb_atom with
        | Some(f) ->
            (match f (Atom.Id k) callb with
            | Atom.Id k -> k
            | _ -> raise_compile_err (get_kexp_loc e)
                "internal error: inside walk_id the callback returned a literal, not id, which is unexpected.")
        | _ -> k in
    let walk_kexp_ e = check_n_walk_kexp e callb in
    let walk_el_ el = List.map walk_kexp_ el in
    let walk_kctx_ (t, loc) = ((walk_ktyp_ t), loc) in
    let walk_dom_ d = check_n_walk_dom d callb in
    let walk_kdl_ kdl = List.map (fun (k, d) -> ((walk_id_ k), (walk_dom_ d))) kdl in
    (match e with
    | KExpNop (_) -> e
    | KExpBreak _ -> e
    | KExpContinue _ -> e
    | KExpAtom (a, ctx) -> KExpAtom((walk_atom_ a), (walk_kctx_ ctx))
    | KExpBinOp(bop, a1, a2, ctx) ->
        KExpBinOp(bop, (walk_atom_ a1), (walk_atom_ a2), (walk_kctx_ ctx))
    | KExpUnOp(uop, a, ctx) -> KExpUnOp(uop, (walk_atom_ a), (walk_kctx_ ctx))
    | KExpIntrin(iop, args, ctx) -> KExpIntrin(iop, (walk_al_ args), (walk_kctx_ ctx))
    | KExpIf(c, then_e, else_e, ctx) ->
        KExpIf((walk_kexp_ c), (walk_kexp_ then_e), (walk_kexp_ else_e), (walk_kctx_ ctx))
    | KExpSeq(elist, ctx) ->
        let rec process_elist elist result =
            match elist with
            | e :: rest ->
                let new_e = walk_kexp_ e in
                let new_result = match e with
                    | KExpNop _ -> if rest != [] then result
                                   else new_e :: result
                    | _ -> new_e :: result in
                process_elist rest new_result
            | _ -> List.rev result in
        let new_elist = process_elist elist [] in
        let (new_ktyp, loc) = walk_kctx_ ctx in
        (match new_elist with
        | [] -> KExpNop(loc)
        | e :: [] -> e
        | _ -> KExpSeq(new_elist, (new_ktyp, loc)))
    | KExpMkTuple(alist, ctx) -> KExpMkTuple((walk_al_ alist), (walk_kctx_ ctx))
    | KExpMkRecord(alist, ctx) -> KExpMkRecord((walk_al_ alist), (walk_kctx_ ctx))
    | KExpMkArray(shape, elems, ctx) -> KExpMkArray(shape, (walk_al_ elems), (walk_kctx_ ctx))
    | KExpCall(f, args, ctx) -> KExpCall((walk_id_ f), (walk_al_ args), (walk_kctx_ ctx))
    | KExpAt(a, idx, ctx) -> KExpAt((walk_atom_ a), (List.map walk_dom_ idx), (walk_kctx_ ctx))
    | KExpAssign(lv, rv, loc) -> KExpAssign((walk_id_ lv), (walk_kexp_ rv), loc)
    | KExpMem(k, member, ctx) -> KExpMem((walk_id_ k), member, (walk_kctx_ ctx))
    | KExpDeref(k, ctx) -> KExpDeref((walk_id_ k), (walk_kctx_ ctx))
    | KExpThrow(k, loc) -> KExpThrow((walk_id_ k), loc)
    | KExpWhile(c, e, loc) -> KExpWhile((walk_kexp_ c), (walk_kexp_ e), loc)
    | KExpDoWhile(c, e, loc) -> KExpDoWhile((walk_kexp_ c), (walk_kexp_ e), loc)
    | KExpFor(kdl, body, flags, loc) ->
        KExpFor((walk_kdl_ kdl), (walk_kexp_ body), flags, loc)
    | KExpMap(e_kdl_l, body, flags, ctx) ->
        KExpMap((List.map (fun (el, kdl) -> ((walk_el_ el), (walk_kdl_ kdl))) e_kdl_l),
                (walk_kexp_ body), flags, (walk_kctx_ ctx))
    | KExpMatch(cases, ctx) ->
        KExpMatch((List.map (fun (checks_i, ei) ->
            ((List.map (fun cij -> walk_kexp_ cij) checks_i), (walk_kexp_ ei))) cases),
            (walk_kctx_ ctx))
    | KExpTryCatch(e1, e2, ctx) ->
        KExpTryCatch((walk_kexp_ e1), (walk_kexp_ e2), (walk_kctx_ ctx))
    | KExpCast(a, t, loc) -> KExpCast((walk_atom_ a), (walk_ktyp_ t), loc)
    | KExpCCode(str, ctx) -> KExpCCode(str, (walk_kctx_ ctx))
    | KDefVal(k, e, loc) ->
        KDefVal((walk_id_ k), (walk_kexp_ e), loc)
    | KDefFun(df) ->
        let { kf_name; kf_typ; kf_args; kf_body; kf_flags; kf_scope; kf_loc } = !df in
        df := { kf_name = (walk_id_ kf_name); kf_typ = (walk_ktyp_ kf_typ);
                kf_args = (List.map walk_id_ kf_args); kf_body = (walk_kexp_ kf_body);
                kf_flags; kf_scope; kf_loc };
        e
    | KDefExn(ke) ->
        let { ke_name; ke_typ; ke_scope; ke_loc } = !ke in
        ke := { ke_name = (walk_id_ ke_name); ke_typ=(walk_ktyp_ ke_typ); ke_scope; ke_loc };
        e
    | KDefVariant(kvar) ->
        let { kvar_name; kvar_cases; kvar_constr; kvar_flags; kvar_scope; kvar_loc } = !kvar in
        kvar := { kvar_name = (walk_id_ kvar_name);
            kvar_cases = (List.map (fun (k, t) -> ((walk_id_ k), (walk_ktyp_ t))) kvar_cases);
            kvar_constr = (List.map walk_id_ kvar_constr); kvar_flags; kvar_scope; kvar_loc };
        e)

(* walk through a K-normalized syntax tree and perform some actions;
   do not construct/return anything (though, it's expected that
   the callbacks collect some information about the tree) *)

type 'x k_fold_callb_t =
{
    kcb_fold_ktyp: (ktyp_t -> 'x k_fold_callb_t -> unit) option;
    kcb_fold_kexp: (kexp_t -> 'x k_fold_callb_t -> unit) option;
    kcb_fold_atom: (atom_t -> 'x k_fold_callb_t -> unit) option;
    mutable kcb_fold_result: 'x;
}

let rec check_n_fold_ktyp t callb =
    match callb.kcb_fold_ktyp with
    | Some(f) -> f t callb
    | _ -> fold_ktyp t callb

and check_n_fold_kexp e callb =
    match callb.kcb_fold_kexp with
    | Some(f) -> f e callb
    | _ -> fold_kexp e callb

and check_n_fold_atom a callb =
    match callb.kcb_fold_atom with
    | Some(f) -> f a callb
    | _ -> ()
and check_n_fold_al al callb =
    List.iter (fun a -> check_n_fold_atom a callb) al

and check_n_fold_dom d callb =
    match d with
    | Domain.Elem a -> check_n_fold_atom a callb
    | Domain.Fast a -> check_n_fold_atom a callb
    | Domain.Range (a, b, c) ->
        check_n_fold_atom a callb;
        check_n_fold_atom b callb;
        check_n_fold_atom c callb

and check_n_fold_id k callb =
    match callb.kcb_fold_atom with
    | Some(f) -> f (Atom.Id k) callb
    | _ -> ()

and fold_ktyp t callb =
    let fold_ktyp_ t = check_n_fold_ktyp t callb in
    let fold_ktl_ tl = List.iter fold_ktyp_ tl in
    let fold_id_ i = check_n_fold_id i callb in
    (match t with
    | KTypInt | KTypSInt _ | KTypUInt _ | KTypFloat _
    | KTypVoid | KTypNil | KTypBool
    | KTypChar | KTypString | KTypCPointer
    | KTypExn | KTypErr | KTypModule -> ()
    | KTypFun (args, rt) -> fold_ktl_ args; fold_ktyp_ rt
    | KTypTuple elems -> fold_ktl_ elems
    | KTypRecord (rn, relems) -> fold_id_ rn;
        List.iter (fun (ni, ti) -> fold_id_ ni; fold_ktyp_ ti) relems
    | KTypName i -> fold_id_ i
    | KTypArray (d, t) -> fold_ktyp_ t
    | KTypList t -> fold_ktyp_ t
    | KTypRef t -> fold_ktyp_ t)

and fold_kexp e callb =
    let fold_atom_ a = check_n_fold_atom a callb in
    let fold_al_ al = List.iter fold_atom_ al in
    let fold_ktyp_ t = check_n_fold_ktyp t callb in
    let fold_id_ k = check_n_fold_id k callb in
    let fold_kexp_ e = check_n_fold_kexp e callb in
    let fold_el_ el = List.iter fold_kexp_ el in
    let fold_kctx_ (t, _) = fold_ktyp_ t in
    let fold_dom_ d = check_n_fold_dom d callb in
    let fold_kdl_ kdl = List.iter (fun (k, d) -> fold_id_ k; fold_dom_ d) kdl in
    fold_kctx_ (match e with
    | KExpNop (l) -> (KTypVoid, l)
    | KExpBreak (l) -> (KTypVoid, l)
    | KExpContinue (l) -> (KTypVoid, l)
    | KExpAtom (a, ctx) -> fold_atom_ a; ctx
    | KExpBinOp(_, a1, a2, ctx) ->
        fold_atom_ a1; fold_atom_ a2; ctx
    | KExpUnOp(_, a, ctx) -> fold_atom_ a; ctx
    | KExpIntrin(_, args, ctx) -> fold_al_ args; ctx
    | KExpIf(c, then_e, else_e, ctx) ->
        fold_kexp_ c; fold_kexp_ then_e; fold_kexp_ else_e; ctx
    | KExpSeq(elist, ctx) -> List.iter fold_kexp_ elist; ctx
    | KExpMkTuple(alist, ctx) -> fold_al_ alist; ctx
    | KExpMkRecord(alist, ctx) -> fold_al_ alist; ctx
    | KExpMkArray(_, elems, ctx) -> fold_al_ elems; ctx
    | KExpCall(f, args, ctx) -> fold_id_ f; fold_al_ args; ctx
    | KExpAt(a, idx, ctx) -> fold_atom_ a; List.iter fold_dom_ idx; ctx
    | KExpAssign(lv, rv, loc) -> fold_id_ lv; fold_kexp_ rv; (KTypVoid, loc)
    | KExpMem(k, _, ctx) -> fold_id_ k; ctx
    | KExpDeref(k, ctx) -> fold_id_ k; ctx
    | KExpThrow(k, loc) -> fold_id_ k; (KTypErr, loc)
    | KExpWhile(c, e, loc) -> fold_kexp_ c; fold_kexp_ e; (KTypErr, loc)
    | KExpDoWhile(c, e, loc) -> fold_kexp_ c; fold_kexp_ e; (KTypErr, loc)
    | KExpFor(kdl, body, _, loc) ->
        fold_kdl_ kdl; fold_kexp_ body; (KTypVoid, loc)
    | KExpMap(e_kdl_l, body, _, ctx) ->
        List.iter (fun (el, kdl) -> fold_el_ el; fold_kdl_ kdl) e_kdl_l;
        fold_kexp_ body; ctx
    | KExpMatch(cases, ctx) ->
        List.iter (fun (checks_i, ei) ->
            List.iter (fun cij -> fold_kexp_ cij) checks_i; fold_kexp_ ei) cases;
        ctx
    | KExpTryCatch(e1, e2, ctx) ->
        fold_kexp_ e1; fold_kexp_ e2; ctx
    | KExpCast(a, t, loc) ->
        fold_atom_ a; (t, loc)
    | KExpCCode(_, ctx) -> ctx
    | KDefVal(k, e, loc) ->
        fold_id_ k; fold_kexp_ e; (KTypVoid, loc)
    | KDefFun(df) ->
        let { kf_name; kf_typ; kf_args; kf_body; kf_loc } = !df in
        fold_id_ kf_name; fold_ktyp_ kf_typ;
        List.iter fold_id_ kf_args; fold_kexp_ kf_body;
        (KTypVoid, kf_loc)
    | KDefExn(ke) ->
        let { ke_name; ke_typ; ke_loc } = !ke in
        fold_id_ ke_name; fold_ktyp_ ke_typ;
        (KTypVoid, ke_loc)
    | KDefVariant(kvar) ->
        let { kvar_name; kvar_cases; kvar_constr; kvar_loc } = !kvar in
        fold_id_ kvar_name;
        List.iter (fun (k, t) -> fold_id_ k; fold_ktyp_ t) kvar_cases;
        List.iter fold_id_ kvar_constr;
        (KTypVoid, kvar_loc))

let add_to_used1 i callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- ((IdSet.add i used_set), decl_set)

let add_to_used uv_set callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- ((IdSet.union uv_set used_set), decl_set)

let add_to_decl1 i callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- (used_set, (IdSet.add i decl_set))

let add_to_decl dv_set callb =
    let (used_set, decl_set) = callb.kcb_fold_result in
    callb.kcb_fold_result <- (used_set, (IdSet.union dv_set decl_set))

let rec used_by_atom_ a callb =
    match a with
    | Atom.Id i -> add_to_used1 i callb
    | _ -> ()
and used_by_ktyp_ t callb = fold_ktyp t callb
and used_by_kexp_ e callb =
    match e with
    | KDefVal(i, e, _) ->
        let (uv, dv) = used_decl_by_kexp e in
        add_to_used uv callb;
        add_to_decl dv callb;
        add_to_decl1 i callb
    | KDefFun {contents={kf_name; kf_typ; kf_args; kf_body}} ->
        (* the function arguments are not included into the "used variables" set by default,
            they should be referenced by the function body to be included *)
        let uv_typ = used_by_ktyp kf_typ in
        let (uv_body, dv_body) = used_decl_by_kexp kf_body in
        let uv = IdSet.union uv_typ (IdSet.remove kf_name uv_body) in
        add_to_used uv callb;
        add_to_decl dv_body callb;
        add_to_decl1 kf_name callb;
        List.iter (fun a -> add_to_decl1 a callb) kf_args
    | KDefExn {contents={ke_name; ke_typ}} ->
        let uv = used_by_ktyp ke_typ in
        add_to_used uv callb;
        add_to_decl1 ke_name callb
    | KDefVariant {contents={kvar_name; kvar_cases}} ->
        let uv = List.fold_left (fun uv (ni, ti) ->
            let uv = IdSet.add ni uv in
            let uv_ti = IdSet.remove kvar_name (used_by_ktyp ti) in
            IdSet.union uv_ti uv) IdSet.empty kvar_cases in
        add_to_used uv callb;
        add_to_decl1 kvar_name callb
    | _ -> fold_kexp e callb

and new_used_vars_callb () =
    {
        kcb_fold_atom = Some(used_by_atom_);
        kcb_fold_ktyp = Some(used_by_ktyp_);
        kcb_fold_kexp = Some(used_by_kexp_);
        kcb_fold_result = (IdSet.empty, IdSet.empty)
    }
and used_by_ktyp t =
    let callb = new_used_vars_callb() in
    let _ = used_by_ktyp_ t callb in
    let (used_set, _) = callb.kcb_fold_result in
    used_set
and used_decl_by_kexp e =
    let callb = new_used_vars_callb() in
    let _ = used_by_kexp_ e callb in
    callb.kcb_fold_result
and used_by_kexp e =
    let (used_set, _) = used_decl_by_kexp e in
    used_set

let used_by code =
    let e = code2kexp code noloc in
    used_by_kexp e

let free_vars_kexp e =
    let (uv, dv) = used_decl_by_kexp e in
    IdSet.diff uv dv

let is_mutable i loc =
    let info = kinfo i in
    check_kinfo info i loc;
    match info with
    | KNone | KText _ -> false
    | KVal {kv_flags} -> List.mem ValMutable kv_flags
    | KFun _ -> false
    | KExn _ -> false
    | KVariant _ -> raise_compile_err loc
        (sprintf "attempt to treat variant '%s' as a value or function" (id2str i))

let print_set setname s =
    printf "%s:[" setname;
    IdSet.iter (fun i -> printf " %s" (id2str i)) s;
    printf " ]\n";