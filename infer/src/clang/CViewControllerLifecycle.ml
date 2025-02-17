(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

let is_view_controller tenv cls =
  let uiviewcontroller = Typ.Name.Objc.from_string "UIViewController" in
  let cls_name = Typ.Name.Objc.from_string cls in
  PatternMatch.is_subtype tenv cls_name uiviewcontroller
  && not (Typ.Name.equal cls_name uiviewcontroller)


let lifecycle_methods =
  [ ("loadView", `NoArg)
  ; ("viewDidLoad", `NoArg)
  ; ("viewWillLayoutSubviews", `NoArg)
  ; ("viewDidLayoutSubviews", `NoArg)
  ; ("viewWillAppear:", `AnimatedArg)
  ; ("viewDidAppear:", `AnimatedArg)
  ; ("viewWillDisappear:", `AnimatedArg)
  ; ("viewDidDisappear:", `AnimatedArg) ]


let is_overriden tenv cls (method_name, arg) =
  match Tenv.lookup tenv cls with
  | Some s ->
      List.find_map s.Struct.methods ~f:(fun m ->
          if String.equal (Procname.get_method m) method_name then Some (m, arg) else None )
  | None ->
      None


let build_view_controller_methods tenv cls loc controller_arg =
  let call_flags = {CallFlags.default with cf_virtual= true} in
  let to_args param =
    match param with
    | `NoArg ->
        []
    | `AnimatedArg ->
        [(Exp.one, {Typ.desc= Typ.Tint IBool; Typ.quals= Typ.mk_type_quals ()})]
  in
  let build_view_controller_method (procname, params) instrs =
    let ret_id = CTrans_utils.mk_fresh_void_id_typ () in
    let args = controller_arg :: to_args params in
    let instr = Sil.Call (ret_id, Const (Cfun procname), args, loc, call_flags) in
    instr :: instrs
  in
  let overriden_methods = List.filter_map ~f:(is_overriden tenv cls) lifecycle_methods in
  List.fold_right ~f:build_view_controller_method ~init:[] overriden_methods


let replace_calls tenv _ proc_desc =
  let add_calls node _ instr =
    let instrs = ProcCfg.Exceptional.instrs node in
    Ident.update_name_generator (Instrs.instrs_get_normal_vars instrs) ;
    let instrs =
      match (instr : Sil.instr) with
      | Call ((ret_id, ret_typ), Const (Cfun callee), _, loc, _) when Procname.is_objc_init callee
        -> (
        match Procname.get_objc_class_name callee with
        | Some cls when is_view_controller tenv cls ->
            let cls_name = Typ.Name.Objc.from_string cls in
            instr :: build_view_controller_methods tenv cls_name loc (Var ret_id, ret_typ)
        | _ ->
            [instr] )
      | _ ->
          [instr]
    in
    Array.of_list instrs
  in
  let update_context () _ = () in
  let context_at_node _ = () in
  ignore
    (Procdesc.replace_instrs_by_using_context proc_desc ~f:add_calls ~update_context
       ~context_at_node )


let process cfg tenv = Procname.Hash.iter (replace_calls tenv) cfg
