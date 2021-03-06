(* We need three sorts of parameters, for types, dirt, and regions.
   In order not to confuse them, we define separate types for them.
 *)
type ty_param = Ty_Param of int
type dirt_param = Dirt_Param of int
type region_param = Region_Param of int

let fresh_ty_param = Common.fresh (fun n -> Ty_Param n)
let fresh_dirt_param = Common.fresh (fun n -> Dirt_Param n)
let fresh_region_param = Common.fresh (fun n -> Region_Param n)

type ty =
  | Apply of Common.tyname * args
  | Param of ty_param
  | Basic of string
  | Tuple of ty list
  | Arrow of ty * dirty
  | Handler of dirty * dirty

and dirty = ty * dirt

and dirt = {
  ops: (Common.effect, region_param) Common.assoc;
  rest: dirt_param
}

and args = (ty, dirt, region_param) Trio.t


let int_ty = Basic "int"
let string_ty = Basic "string"
let bool_ty = Basic "bool"
let float_ty = Basic "float"
let unit_ty = Tuple []
let empty_ty = Apply ("empty", Trio.empty)

(** [fresh_ty ()] gives a type [Param p] where [p] is a new type parameter on
    each call. *)
let fresh_ty () = Param (fresh_ty_param ())
let simple_dirt d = { ops = []; rest = d }
let fresh_dirt () = simple_dirt (fresh_dirt_param ())
let fresh_dirty () = (fresh_ty (), fresh_dirt ())

(* These types are used when type checking is turned off. Their names
   are syntactically incorrect so that the programmer cannot accidentally
   define it. *)
let universal_ty = Basic "_"
let universal_dirty = (Basic "_", fresh_dirt ())


type replacement = {
  ty_param_repl : ty_param -> ty;
  dirt_param_repl : dirt_param -> dirt;
  region_param_repl : region_param -> region_param;
}

(** [replace_ty rpls ty] replaces type parameters in [ty] according to [rpls]. *)
let rec replace_ty rpls = function
  | Apply (ty_name, args) -> Apply (ty_name, replace_args rpls args)
  | Param p -> rpls.ty_param_repl p
  | Basic _ as ty -> ty
  | Tuple tys -> Tuple (Common.map (replace_ty rpls) tys)
  | Arrow (ty1, (ty2, drt)) ->
      let ty1 = replace_ty rpls ty1 in
      let drt = replace_dirt rpls drt in
      let ty2 = replace_ty rpls ty2 in
      Arrow (ty1, (ty2, drt))
  | Handler (drty1, drty2) ->
      let drty1 = replace_dirty rpls drty1 in
      let drty2 = replace_dirty rpls drty2 in
      Handler (drty1, drty2)

and replace_dirt rpls drt =
  let ops = Common.assoc_map rpls.region_param_repl drt.ops in
  let { ops = new_ops; rest = new_rest } = rpls.dirt_param_repl drt.rest in
  { ops = new_ops @ ops; rest = new_rest }

and replace_dirty rpls (ty, drt) =
  let ty = replace_ty rpls ty in
  let drt = replace_dirt rpls drt in
  (ty, drt)

and replace_args rpls (tys, drts, rs) =
  let tys = Common.map (replace_ty rpls) tys in
  let drts = Common.map (replace_dirt rpls) drts in
  let rs = Common.map rpls.region_param_repl rs in
  (tys, drts, rs)

type substitution = {
  ty_param : ty_param -> ty_param;
  dirt_param : dirt_param -> dirt_param;
  region_param : region_param -> region_param;
}

(** [subst_ty sbst ty] replaces type parameters in [ty] according to [sbst]. *)
let rec subst_ty sbst = function
  | Apply (ty_name, args) -> Apply (ty_name, subst_args sbst args)
  | Param p -> Param (sbst.ty_param p)
  | Basic _ as ty -> ty
  | Tuple tys -> Tuple (Common.map (subst_ty sbst) tys)
  | Arrow (ty1, (ty2, drt)) ->
      let ty1 = subst_ty sbst ty1 in
      let drt = subst_dirt sbst drt in
      let ty2 = subst_ty sbst ty2 in
      Arrow (ty1, (ty2, drt))
  | Handler (drty1, drty2) ->
      let drty1 = subst_dirty sbst drty1 in
      let drty2 = subst_dirty sbst drty2 in
      Handler (drty1, drty2)

and subst_dirt sbst {ops; rest} =
  { ops = Common.assoc_map sbst.region_param ops; rest = sbst.dirt_param rest }

and subst_dirty sbst (ty, drt) =
  let ty = subst_ty sbst ty in
  let drt = subst_dirt sbst drt in
  (ty, drt)

and subst_args sbst (tys, drts, rs) =
  let tys = Common.map (subst_ty sbst) tys in
  let drts = Common.map (subst_dirt sbst) drts in
  let rs = Common.map sbst.region_param rs in
  (tys, drts, rs)

(** [identity_subst] is a substitution that makes no changes. *)
let identity_subst =
  {
    ty_param = Common.id;
    dirt_param = Common.id;
    region_param = Common.id;
  }

(** [compose_subst sbst1 sbst2] returns a substitution that first performs
    [sbst2] and then [sbst1]. *)
let compose_subst sbst1 sbst2 =
  {
    ty_param = Common.compose sbst1.ty_param sbst2.ty_param;
    dirt_param = Common.compose sbst1.dirt_param sbst2.dirt_param;
    region_param = Common.compose sbst1.region_param sbst2.region_param;
  }

let refresher fresh =
  let substitution = ref [] in
  fun p ->
    match Common.lookup p !substitution with
    | None ->
        let p' = fresh () in
        substitution := Common.update p p' !substitution;
        p'
    | Some p' -> p'

let beautifying_subst () =
  if !Config.disable_beautify then
    identity_subst
  else
    {
      ty_param = refresher (Common.fresh (fun n -> Ty_Param n));
      dirt_param = refresher (Common.fresh (fun n -> Dirt_Param n));
      region_param = refresher (Common.fresh (fun n -> Region_Param n));
    }

let refreshing_subst () =
  {
    ty_param = refresher fresh_ty_param;
    dirt_param = refresher fresh_dirt_param;
    region_param = refresher fresh_region_param;
  }

let refresh ty =
  let sbst = refreshing_subst () in
  subst_ty sbst ty

let (@@@) = Trio.append

let for_parameters get_params is_pos ps lst =
  List.fold_right2 (fun (_, (cov, contra)) el params ->
                      let params = if cov then get_params is_pos el @@@ params else params in
                      if contra then get_params (not is_pos) el @@@ params else params) ps lst Trio.empty

let pos_neg_params get_variances ty =
  let rec pos_ty is_pos = function
  | Apply (ty_name, args) -> pos_args is_pos ty_name args
  | Param p -> ((if is_pos then [p] else []), [], [])
  | Basic _ -> Trio.empty
  | Tuple tys -> Trio.flatten_map (pos_ty is_pos) tys
  | Arrow (ty1, drty2) -> pos_ty (not is_pos) ty1 @@@ pos_dirty is_pos drty2
  | Handler ((ty1, drt1), drty2) -> pos_ty (not is_pos) ty1 @@@ pos_dirt (not is_pos) drt1 @@@ pos_dirty is_pos drty2
  and pos_dirty is_pos (ty, drt) =
    pos_ty is_pos ty @@@ pos_dirt is_pos drt
  and pos_dirt is_pos drt =
    pos_dirt_param is_pos drt.rest @@@ Trio.flatten_map (fun (_, dt) -> pos_region_param is_pos dt) drt.ops
  and pos_dirt_param is_pos p =
    ([], (if is_pos then [p] else []), [])
  and pos_region_param is_pos r =
    ([], [], if is_pos then [r] else [])
  and pos_args is_pos ty_name (tys, drts, rgns) =
    let (ps, ds, rs) = get_variances ty_name in
    for_parameters pos_ty is_pos ps tys @@@
    for_parameters pos_dirt is_pos ds drts @@@
    for_parameters pos_region_param is_pos rs rgns
  in
  Trio.uniq (pos_ty true ty), Trio.uniq (pos_ty false ty)

let print_ty_param (Ty_Param k) ppf =
  Symbols.ty_param k false ppf

let print_dirt_param (Dirt_Param k) ppf =
  Symbols.dirt_param k false ppf

let print_region_param (Region_Param k) ppf =
  Symbols.region_param k false ppf

let print_dirt drt ppf =
  match drt.ops with
  | [] ->
      Print.print ppf "%t" (print_dirt_param drt.rest)
  | _ ->
      let print_operation (op, r) ppf =
        Print.print ppf "%s:%t" op (print_region_param r)
      in
      Print.print ppf "{%t|%t}"
        (Print.sequence ", " print_operation drt.ops)
        (print_dirt_param drt.rest)

let rec print_ty ?max_level ty ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  match ty with
  | Apply (ty_name, ([], _, _)) ->
      print "%s" ty_name
  | Apply (ty_name, ([ty], _, _)) ->
      print ~at_level:1 "%t %s" (print_ty ~max_level:1 ty) ty_name
  | Apply (ty_name, (tys, _, _)) ->
      print ~at_level:1 "(%t) %s" (Print.sequence ", " print_ty tys) ty_name
  | Param p -> print_ty_param p ppf
  | Basic b -> print "%s" b
  | Tuple [] -> print "unit"
  | Tuple tys ->
      print ~at_level:2 "@[<hov>%t@]"
      (Print.sequence (Symbols.times ()) (print_ty ~max_level:1) tys)
  | Arrow (t1, (t2, drt)) ->
      print ~at_level:5 "@[%t -%t%s@ %t@]"
        (print_ty ~max_level:4 t1)
        (print_dirt drt)
        (Symbols.short_arrow ())
        (print_ty ~max_level:5 t2)
  | Handler ((t1, drt1), (t2, drt2)) ->
      print ~at_level:6 "%t ! %t %s@ %t ! %t"
        (print_ty ~max_level:4 t1)
        (print_dirt drt1)
        (Symbols.handler_arrow ())
        (print_ty ~max_level:4 t2)
        (print_dirt drt2)
