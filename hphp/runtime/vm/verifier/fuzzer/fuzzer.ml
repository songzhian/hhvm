(*
   +----------------------------------------------------------------------+
   | HipHop for PHP                                                       |
   +----------------------------------------------------------------------+
   | Copyright (c) 2010-present Facebook, Inc. (http://www.facebook.com)  |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
*)

(* This fuzzer works by applying semi-random mutations of different kinds to a
   hhas input file. Given a starter program, each mutation will generate a
   sample space of outcomes, the size of which is determined by user input. The
   process is structured around the non-determinism monad, so that each mutation
   is applied to every program in the output space of the previous mutation.
   Because the mutation includes its input in the output space, the output of
   the whole process includes every combination of the mutations applied at each
   step. *)

(*---------------------------------File I/0-----------------------------------*)

let out_dir = ref ""
let imm_reps = ref 1
let dup_reps = ref 1
let reorder_reps = ref 1
let replace_reps = ref 1
let remove_reps = ref 1
let insert_reps = ref 1
let metadata_reps = ref 1
let complete_reps = ref 0
let mut_prob = ref 0.1
let mag = ref 1
let mut_stk = ref true
let debug = ref false

let options =
  [("-o",         Arg.Set_string out_dir,
      "The output directory for the mutations");
   ("-out",       Arg.Set_string out_dir,
      "The output directory for the mutations");
   ("-prob",      Arg.Set_float mut_prob,
      "The probability of a mutation occuring each pass (must be <= 1)");
   ("-magnitude", Arg.Set_int mag,
      "The magnitude of possible change for integer mutations (default 1)");
   ("-stack", Arg.Set mut_stk,
      "Whether to allow mutations of stack offsets (default true)");
  ("-debug", Arg.Set debug,
      "Turn on debug prints (default false)");
   ("-immediate", Arg.Set_int imm_reps,
      "Number of immediate mutations (default 1)");
   ("-duplicate", Arg.Set_int dup_reps,
      "Number of duplicate mutations (default 1)");
   ("-reorder",   Arg.Set_int reorder_reps,
      "Number of reorder mutations (default 1)");
   ("-replace",   Arg.Set_int replace_reps,
      "Number of replace mutations (default 1)");
   ("-remove",    Arg.Set_int remove_reps,
      "Number of remove mutations (default 1)");
   ("-insert",    Arg.Set_int insert_reps,
      "Number of insert mutations (default 1)");
   ("-metadata",  Arg.Set_int metadata_reps,
      "Number of metadata mutations (default 1)");
   ("-complete", Arg.Set_int complete_reps,
      "Number of complete mutations (default 0,
      overrides other mutation parameters)")
  ]

let print_output : Hhas_program.t -> unit =
  let m_no = ref 0 in
  fun (p : Hhas_program.t) ->
    let out =
      if !out_dir <> ""
      then open_out (!out_dir ^ "/mutation" ^ string_of_int(!m_no) ^ ".hhas")
      else stdout in
    p |> Hhbc_hhas.to_string |> (Printf.fprintf out "#Mutation %d\n%s\n" !m_no);
    if (!out_dir <> "") then close_out out;
    m_no := !m_no + 1

let parse_file program_parser filename =
  let channel = open_in filename in
  let prog =
    try program_parser (Lexing.from_channel channel)
    with Parsing.Parse_error -> (
      Printf.eprintf "Parsing of file failed\n";
      raise Parsing.Parse_error
      ) in
  close_in channel; prog

let read_input () : Hhas_program.t =
  let filename = ref ""  in
  let purpose = "Hhas fuzzing tool" in
  let usage = Printf.sprintf "%s\nUsage: %s <file> -o <output dir>"
              purpose Sys.argv.(0) in
  Arg.parse options (fun file -> filename := file) usage;
  let program_parser = Hhas_parser.program Hhas_lexer.read in
  parse_file program_parser !filename

(*---------------------------------Mutations----------------------------------*)

module IS = Instruction_sequence
module HP = Hhas_program
open Instr_utils

type mutation_monad = HP.t Nondet.m
type mutation = HP.t -> mutation_monad

(* These couple of functions are just plumbing the Hhas_program data structure
   to access the instruction sequences, which is where the real work happens,
   and then reconstructing the program with the new, mutated sequences *)

let mutate_body (mut: IS.t -> IS.t) (b : Hhas_body.t) : Hhas_body.t =
  Hhas_body.instrs b |> mut |> Hhas_body.with_instrs b

let mutate_main (mut: IS.t -> IS.t) (p : HP.t) : Hhas_program.t =
  HP.main p |> mutate_body mut |> HP.with_main p

let mutate_functions (mut: IS.t -> IS.t) (p : HP.t) : Hhas_program.t =
  let mutate_function (f : Hhas_function.t) : Hhas_function.t =
    Hhas_function.body f |> mutate_body mut |> Hhas_function.with_body f in
  HP.functions p |> List.map mutate_function |> HP.with_fun p

let mutate_methods (mut: IS.t -> IS.t) (p : HP.t) : Hhas_program.t =
  let mutate_method (m : Hhas_method.t) : Hhas_method.t =
    Hhas_method.body m |> mutate_body mut |> Hhas_method.with_body m in
  let mutate_class (c : Hhas_class.t) : Hhas_class.t =
    Hhas_class.methods c |> List.map mutate_method |>
    Hhas_class.with_methods c in
  HP.classes p |> List.map mutate_class |> HP.with_classes p

let mutate_program (mut: IS.t -> IS.t) (p : HP.t) : Hhas_program.t =
  p |> mutate_main mut |> mutate_functions mut |> mutate_methods mut

let mutate (mut: IS.t -> IS.t) (prog : HP.t) n (acc: mutation_monad) =
  num_fold (fun a -> mutate_program mut prog |> Nondet.add_event a) n acc

open Hhbc_ast

let option_lift f = function
| Some x -> Some (f x)
| None -> None

let rand_elt lst =
  let i = Random.int (List.length lst) in
  List.nth lst i

let should_mutate () = Random.float 1.0 < !mut_prob

let mutate_bool b = if should_mutate() then not b else b

let mutate_int n c =    (*TODO: in what cases is it okay to generate negative
                          numbers?*)
  if should_mutate () then n + (Random.int (2 * (c+1))) - c |> max 0 else n

let mutate_local_id (id : Local.t) c =
  match id with
  | Local.Unnamed i -> Local.Unnamed (mutate_int i c)
  | _ -> id (*TODO: is it worth it to mutate named locals? I think this would
              create trivially non-verifying programs in almost all cases,
              so it wouldn't be that interesting *)

(* Changes the input label to another with the same stack height *)
let mutate_label data (label : Label.t) =
  if not (should_mutate()) then label else
  let height l = data.stack_history |> List.assoc l |> List.length in
  let init_height = height (ILabel label) in
  List.filter (fun l -> init_height = height (ILabel l)) data.labels |> rand_elt

let mutate_key (k : MemberKey.t) c =
  let new_key_type n =
    [MemberKey.EC n; MemberKey.EL (Local.Unnamed n); MemberKey.PC n;
     MemberKey.EI (Int64.of_int n); MemberKey.PL (Local.Unnamed n)] |>
    rand_elt in
  let swap_key_type k =
    match k with
    | MemberKey.EC n -> if should_mutate() then new_key_type n else k
    | MemberKey.PC n -> if should_mutate() then new_key_type n else k
    | MemberKey.EI n ->
        if should_mutate() then new_key_type (Int64.to_int n)  else k
    | MemberKey.EL (Local.Unnamed n) ->
        if should_mutate() then new_key_type n                 else k
    | MemberKey.PL (Local.Unnamed n) ->
        if should_mutate() then new_key_type n                 else k
    | _ -> k in
  match swap_key_type k with
  | MemberKey.EC i   -> MemberKey.EC (mutate_int      i  c)
  | MemberKey.EL id  -> MemberKey.EL (mutate_local_id id c)
  | MemberKey.PC i   -> MemberKey.PC (mutate_int      i  c)
  | MemberKey.PL id  -> MemberKey.PL (mutate_local_id id c)
  | MemberKey.EI i   ->
      MemberKey.EI (Int64.of_int (mutate_int (Int64.to_int i) c))
  | _ -> k (*TODO: mutate other kinds of member keys. Need to keep track of
            valid prop ids*)

(* TODO: Given the fact that we explicitly check this in the verifier as of
   D5169792, is this even worth doing here? It will always produce non-verifying
   code*)
let mutate_mode (m : MemberOpMode.t) =
  if should_mutate()
  then [MemberOpMode.ModeNone; MemberOpMode.Define; MemberOpMode.Warn;
        MemberOpMode.Unset] |> rand_elt
  else m

let maintain_stack op data =
  let pc, stk = ref 0, ref [] in (* This is a cool scoping trick that lets *)
  fun (i : instruct) ->          (* these refs get defined before the instr *)
  pc := !pc + 1;                 (* gets applied. Thus when this function is *)
  let new_instructs = op data i in  (* is used later as an argument to *)
  let helper instr buffer =    (* flat_map, the internal state is not exposed *)
    let ctrl_buffer =
      match instr with
      | IContFlow RetC
      | IContFlow RetV   ->
          let old_stk = !stk in
          stk := num_fold List.tl ((List.length !stk)-1) !stk;
          empty_stk old_stk 1
      | IContFlow Unwind
      | IMisc NativeImpl -> let old_stk = !stk in
                            stk := []; empty_stk old_stk 0
      | ILabel _
      | IIterator _
      | IContFlow _      ->
        let orig_stack = snd (List.nth data.stack_history (!pc - 1)) in
        let res = equate_stk !stk orig_stack in
        stk := orig_stack; res
      | _ -> [] in
    let stk_req, stk_prod = stk_data instr in
    let num_req = List.length stk_req - List.length !stk in
    let pre_buffer, stk_extra =
      if num_req > 0 then rebalance_stk num_req stk_req
      else [],[] in
    if !debug then begin
      Printf.printf "Instruction %s stack is [%s],
                     consumed [%s], produced [%s]\n"
      (Hhbc_hhas.string_of_instruction instr) (string_of_stack !stk)
      (string_of_stack stk_req) (string_of_stack stk_prod)
    end;
    stk := stk_extra @ !stk;
    stk := List.fold_left (fun acc _ -> List.tl acc) !stk stk_req;
    stk := List.fold_left (fun acc x -> x::acc) !stk stk_prod;
    buffer @ pre_buffer @ ctrl_buffer @ [instr] in
  List.fold_right helper new_instructs []

let mut_imms (is : IS.t) : IS.t =
  let mutate_get s =
    match s with    (*TODO: clean this up if OCaml ever gets macros *)
    | CGetL       id     -> CGetL      (mutate_local_id id !mag)
    | CGetQuietL  id     -> CGetQuietL (mutate_local_id id !mag)
    | CGetL2      id     -> CGetL2     (mutate_local_id id !mag)
    | CGetL3      id     -> CGetL3     (mutate_local_id id !mag)
    | PushL       id     -> PushL      (mutate_local_id id !mag)
    | CGetS       i      -> CGetS      (mutate_int      i  !mag)
    | VGetL       id     -> VGetL      (mutate_local_id id !mag)
    | VGetS       i      -> VGetS      (mutate_int      i  !mag)
    | ClsRefGetC  i      -> ClsRefGetC (mutate_int      i  !mag)
    | ClsRefGetL (id, i) ->
        ClsRefGetL ((mutate_local_id id !mag), (mutate_int i !mag))
    | _ -> s in  (*TODO: in general it might be worthwhile to get rid of wild
                   card cases like this. It would make the code more verbose,
                   but it will make adding new bytecodes easier since this will
                   just stop compiling whenever that happens *)
  let mutate_isset s =
    match s with
    | IssetL   id        -> IssetL  (mutate_local_id id !mag)
    | IssetS   i         -> IssetS  (mutate_int      i  !mag)
    | EmptyL   id        -> EmptyL  (mutate_local_id id !mag)
    | EmptyS   i         -> EmptyS  (mutate_int      i  !mag)
    | IsTypeL (id, op)   -> IsTypeL (mutate_local_id id !mag, op)
    | _ -> s in
  let mutate_mutator s =
    match s with
    | SetL      id       -> SetL    (mutate_local_id id !mag)
    | SetS      i        -> SetS    (mutate_int      i  !mag)
    | SetOpL   (id, op)  -> SetOpL  (mutate_local_id id !mag, op)
    | SetOpS   (op, i )  -> SetOpS  (op, mutate_int  i  !mag)
    | IncDecL  (id, op)  -> IncDecL (mutate_local_id id !mag, op)
    | IncDecS  (op, i )  -> IncDecS (op, mutate_int  i  !mag)
    | BindL     id       -> BindL   (mutate_local_id id !mag)
    | BindS     i        -> BindS   (mutate_int      i  !mag)
    | UnsetL    id       -> UnsetL  (mutate_local_id id !mag)
    | CheckProp p        -> CheckProp p (*TODO: figure out how to mutate these*)
    | InitProp (p, Static) ->
        InitProp(p, if should_mutate() then NonStatic else Static)
    | InitProp (p, NonStatic) ->
        InitProp(p, if should_mutate() then Static else NonStatic)
    | _ -> s in
  let mutate_call data s =
    match s with (*It's not worth mutating arg numbers for Push* or Call*,
                   because we already know it will fail the verifier/assembler*)
    | FPushObjMethod   (i, Ast_defs.OG_nullthrows)    ->
         FPushObjMethod(i,    if should_mutate()
                              then Ast_defs.OG_nullsafe  (*What do these do?*)
                              else Ast_defs.OG_nullthrows)
    | FPushObjMethod   (i, Ast_defs.OG_nullsafe)      ->
         FPushObjMethod(i,    if should_mutate()
                              then Ast_defs.OG_nullthrows
                              else Ast_defs.OG_nullsafe)
    | FPushObjMethodD  (i, m, Ast_defs.OG_nullthrows) ->
        FPushObjMethodD(i, m, if should_mutate()
                              then Ast_defs.OG_nullsafe
                              else Ast_defs.OG_nullthrows)
    | FPushObjMethodD  (i, m, Ast_defs.OG_nullsafe)   ->
        FPushObjMethodD(i, m, if should_mutate()
                              then Ast_defs.OG_nullthrows
                              else Ast_defs.OG_nullsafe)
    | FPushCtor     (i, id) -> FPushCtor  (i, mutate_int        id !mag)
    | FPushCtorI    (i, id) -> FPushCtorI (i, mutate_int        id !mag)
    | DecodeCufIter (i, id) -> DecodeCufIter (mutate_int        i  !mag,
                                              mutate_label data id)
    | FPassS        (i, id) -> FPassS        (mutate_int        i  !mag,
                                              mutate_int        id !mag)
    | FPassL        (i, id) -> FPassL        (mutate_int        i  !mag,
                                              mutate_local_id   id !mag)
    | FPassC         i      -> FPassC        (mutate_int        i  !mag)
    | FPassCW        i      -> FPassCW       (mutate_int        i  !mag)
    | FPassCE        i      -> FPassCE       (mutate_int        i  !mag)
    | FPassV         i      -> FPassV        (mutate_int        i  !mag)
    | FPassVNop      i      -> FPassVNop     (mutate_int        i  !mag)
    | FPassR         i      -> FPassR        (mutate_int        i  !mag)
    | FPassN         i      -> FPassN        (mutate_int        i  !mag)
    | FPassG         i      -> FPassG        (mutate_int        i  !mag)
    | _ -> s in
  let mutate_base s =
    match s with
    | BaseNC    (idx, mode) -> BaseNC (mutate_int      idx !mag,
                                       mutate_mode         mode)
    | BaseNL    (id,  mode) -> BaseNL (mutate_local_id id  !mag,
                                       mutate_mode         mode)
    | BaseGC    (idx, mode) -> BaseGC (mutate_int      idx !mag,
                                       mutate_mode         mode)
    | BaseGL    (id,  mode) -> BaseGL (mutate_local_id id  !mag,
                                       mutate_mode         mode)
    | BaseL     (id,  mode) -> BaseL  (mutate_local_id id  !mag,
                                       mutate_mode         mode)
    | FPassBaseNC (i,  idx) -> FPassBaseNC (i, mutate_int      idx !mag)
    | FPassBaseNL (i,   id) -> FPassBaseNL (i, mutate_local_id id  !mag)
    | FPassBaseGC (i,  idx) -> FPassBaseGC (i, mutate_int      idx !mag)
    | FPassBaseGL (i,   id) -> FPassBaseGL (i, mutate_local_id id  !mag)
    | BaseSC      (idx,  i) -> BaseSC         (mutate_int      idx !mag,
                                               mutate_int      i   !mag)
    | BaseSL      (id, idx) -> BaseSL         (mutate_local_id id  !mag,
                                               mutate_int      idx !mag)
    | FPassBaseL  (i,   id) -> FPassBaseL  (i, mutate_local_id id  !mag)
    | BaseC        idx      -> BaseC    (mutate_int idx !mag)
    | BaseR        idx      -> BaseR    (mutate_int idx !mag)
    | Dim       (mode, key) -> Dim      (mutate_mode  mode, mutate_key key !mag)
    | FPassDim    (i,  key) -> FPassDim (mutate_int i !mag, mutate_key key !mag)
    | _ -> s in
  let mutate_ctrl_flow data s =
    match s with
    | Switch (Bounded, n, v) ->
        Switch ((if should_mutate() then Unbounded else Bounded),
        mutate_int n !mag, v)
    | Switch (Unbounded, n, v) ->
        Switch ((if should_mutate() then Bounded else Unbounded),
        mutate_int n !mag, v)
    | Jmp   l -> Jmp   (mutate_label data l)
    | JmpNS l -> JmpNS (mutate_label data l)
    | JmpZ  l -> JmpZ  (mutate_label data l)
    | JmpNZ l -> JmpNZ (mutate_label data l)
    | SSwitch lst ->
        SSwitch (List.map (fun (id, l) -> (id, mutate_label data l)) lst)
    | _ -> s in
  let mutate_final s =
    let mutate_op op =
      if should_mutate()
      then [QueryOp.CGet; QueryOp.CGetQuiet; QueryOp.Isset; QueryOp.Empty] |>
            rand_elt
      else op in
    match s with
    | QueryM  (i, op, k) ->
        QueryM (mutate_int i !mag,   mutate_op      op,      mutate_key k !mag)
    | FPassM  (i, i', k) ->
        FPassM (mutate_int i !mag,   mutate_int i' !mag,     mutate_key k !mag)
    | VGetM   (i,     k) -> VGetM   (mutate_int i  !mag,     mutate_key k !mag)
    | SetM    (i,     k) -> SetM    (mutate_int i  !mag,     mutate_key k !mag)
    | IncDecM (i, op, k) -> IncDecM (mutate_int i  !mag, op, mutate_key k !mag)
    | SetOpM  (i, op, k) -> SetOpM  (mutate_int i  !mag, op, mutate_key k !mag)
    | BindM   (i,     k) -> BindM   (mutate_int i  !mag,     mutate_key k !mag)
    | UnsetM  (i,     k) -> UnsetM  (mutate_int i  !mag,     mutate_key k !mag)
    | SetWithRefLML (id, id') ->
        SetWithRefLML (mutate_local_id id !mag, mutate_local_id id' !mag)
    | SetWithRefRML  id  -> SetWithRefRML (mutate_local_id id !mag) in

  let mutate_iterator data s =
    match s with
    | IterInit   (i, l, id)      ->
        IterInit   (i, mutate_label data l,      mutate_local_id id  !mag)
    | IterInitK  (i, l, id, id') ->
        IterInitK  (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | WIterInit  (i, l, id)      ->
        WIterInit  (i, mutate_label data l,      mutate_local_id id  !mag)
    | WIterInitK (i, l, id, id') ->
        WIterInitK (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | MIterInit  (i, l, id)      ->
        MIterInit  (i, mutate_label data l,      mutate_local_id id  !mag)
    | MIterInitK (i, l, id, id') ->
        MIterInitK (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | IterNext   (i, l, id)      ->
        IterNext   (i, mutate_label data l,      mutate_local_id id  !mag)
    | IterNextK  (i, l, id, id') ->
        IterNextK  (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | WIterNext  (i, l, id)      ->
        WIterNext  (i, mutate_label data l,      mutate_local_id id  !mag)
    | WIterNextK (i, l, id, id') ->
        WIterNextK (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | MIterNext  (i, l, id)      ->
        MIterNext  (i, mutate_label data l,      mutate_local_id id  !mag)
    | MIterNextK (i, l, id, id') ->
        MIterNextK (i, mutate_label data l,
                       mutate_local_id  id !mag, mutate_local_id id' !mag)
    | IterBreak  (l, lst)        ->
        IterBreak     (mutate_label data l,
                       List.map (fun (b, i) -> (mutate_bool b, i)) lst)
    | _ -> s in
  let mutate_misc s =
    let mutate_bare op =
      if should_mutate() then [Notice; NoNotice] |> rand_elt else op in
    let mutate_kind k =
      if should_mutate() then [KClass; KInterface; KTrait] |> rand_elt else k in
    let mutate_param_id id c =
      match id with
      | Param_unnamed i -> Param_unnamed (mutate_int i c)
      | _ -> id in (*TODO: is it worth it to mutate named params? I think this
                     would create trivially non-verifying programs in almost all
                     cases, so it wouldn't be that interesting *)
   let mutate_silence op =
     if should_mutate() then [Start; End] |> rand_elt else op in
    match s with
    | BareThis        b       -> BareThis        (mutate_bare            b)
    | InitThisLoc    id       -> InitThisLoc     (mutate_local_id id  !mag)
    | StaticLocCheck (id, str) -> StaticLocCheck (mutate_local_id id  !mag, str)
    | StaticLocInit  (id, str) -> StaticLocInit  (mutate_local_id id  !mag, str)
    | StaticLocDef  (id, str)  -> StaticLocDef   (mutate_local_id id  !mag, str)
    | OODeclExists    k       -> OODeclExists    (mutate_kind            k)
    | VerifyParamType p       -> VerifyParamType (mutate_param_id p   !mag)
    | Self            i       -> Self            (mutate_int      i   !mag)
    | Parent          i       -> Parent          (mutate_int      i   !mag)
    | LateBoundCls    i       -> LateBoundCls    (mutate_int      i   !mag)
    | ClsRefName      i       -> ClsRefName      (mutate_int      i   !mag)
    | IncStat        (i,  i') -> IncStat         (mutate_int      i   !mag,
                                                  mutate_int      i'  !mag)
    | CreateCl       (i,  i') -> CreateCl        (mutate_int      i   !mag,
                                                  mutate_int      i'  !mag)
    | GetMemoKeyL    id       -> GetMemoKeyL     (mutate_local_id id !mag)
    | Silence (id, op) -> Silence (mutate_local_id id !mag, mutate_silence op)
    | MemoSet     (i, id, i') ->
        MemoSet (mutate_int i !mag, mutate_local_id id !mag, mutate_int i' !mag)
    | MemoGet     (i, id, i') ->
        MemoGet (mutate_int i !mag, mutate_local_id id !mag, mutate_int i' !mag)
    | _ -> s in
  let change_imms data (i : instruct) : instruct list =
    [match i with
     | IContFlow s -> IContFlow (mutate_ctrl_flow data s)
     | IMutator  s -> IMutator  (mutate_mutator        s)
     | IGet      s -> IGet      (mutate_get            s)
     | IIsset    s -> IIsset    (mutate_isset          s)
     | ICall     s -> ICall     (mutate_call      data s)
     | IBase     s -> IBase     (mutate_base           s)
     | IFinal    s -> IFinal    (mutate_final          s)
     | IIterator s -> IIterator (mutate_iterator  data s)
     | IMisc     s -> IMisc     (mutate_misc           s)
     | _ -> i] (*no immediates, or none worth mutating*) in
  IS.InstrSeq.flat_map is (maintain_stack change_imms (seq_data is))

(* Mutates the immediates of the opcodes in the input program. Currently
   this is just naive, randomly changing integer values by a user specified
   magnitude, and changing enum-style values by choosing a random new value
   in the possiblity space. *)
let mutate_immediate (input : HP.t) : mutation_monad =
  if !debug then print_endline "Mutating immediates";
  mutate mut_imms input !imm_reps (Nondet.return input)

(* This will randomly duplicate an instruction by inserting another copy into
   its instruction sequences. *)
let mutate_duplicate (input : HP.t) : mutation_monad =
  if !debug then print_endline "Duplicating";
  let mut (is : IS.t) =
    let duplicate _ i =
      match i with
      | ILabel _
      | ICall _
      | ITry _
      | IContFlow _ -> [i] (*duplicating control flow just breaks the stack*)
      | _ -> if should_mutate() then [i; i] else [i] in
    IS.InstrSeq.flat_map is (maintain_stack duplicate (seq_data is)) in
  mutate mut input !dup_reps (Nondet.return input)

(* This will randomly swap the position of two instructions in sequence. TODO:
   same as above *)
let mutate_reorder (input : HP.t) : mutation_monad =
  if !debug then print_endline "Reordering";
  let rec flatten (lst : IS.t list) =
     match lst with
     | [] -> []
     | IS.Instr_list l1 :: IS.Instr_list l2 :: t ->
        flatten (IS.instrs (l1@l2)::t)  (*TODO: this process seems less
                                        efficient than it could be*)
     | IS.Instr_concat l :: t -> flatten l @ flatten t |> flatten
     | h :: t -> h::(flatten t) in
  let rec mut (is : IS.t) =
    let rec reorder = function  (* TODO: Make this tail recursive? *)
    | [] -> []
    | [h] -> [h]
    | h1::h2::t -> if should_mutate()
                   then h2::h1::reorder(t)
                   else h1::reorder(h2::t) in
    match is with
    | IS.Instr_list lst -> IS.Instr_list (reorder lst)
    | IS.Instr_concat lst -> IS.Instr_concat (List.map mut (flatten lst))
    | IS.Instr_try_fault (is1, is2) -> IS.Instr_try_fault (mut is1, mut is2) in
  mutate mut input !reorder_reps (Nondet.return input)

(* This will randomly remove some of the instructions in a sequence. *)
let mutate_remove (input : HP.t) : mutation_monad =
  if !debug then print_endline "Removing";
  let remove _ i =
    match i with
    | ILabel _
    | ICall _
    | ITry _
    | IContFlow _ -> [i] (*removing control flow just breaks the stack*)
    | _ -> if should_mutate() then [] else [i] in
  let mut (is : IS.t) =
    IS.InstrSeq.flat_map is (maintain_stack remove (seq_data is)) in
  mutate mut input !remove_reps  (Nondet.return input)

let mutate_replace (input : HP.t) : mutation_monad =
  let mut _ = failwith "TODO" in
  mutate mut input !replace_reps (Nondet.return input)

let mutate_insert (input : HP.t) : mutation_monad =
  let mut _ = failwith "TODO" in
  mutate mut input !insert_reps  (Nondet.return input)

let mutate_metadata (input : HP.t)  =
  if !debug then print_endline "Mutating metadata";
  let rec delete_map f = function
    | [] -> []
    | h::t -> if should_mutate()
              then delete_map f t
              else (f h)::delete_map f t in
  let mutate_option opt =
    if not (should_mutate()) then opt else None in
  let mutate_typed_value (v : Typed_value.t) : Typed_value.t =
    if not (should_mutate()) then v else
    [Typed_value.Uninit; Typed_value.Int (Int64.of_int 1);
     Typed_value.Bool true; Typed_value.Float 0.1;
     Typed_value.String ""; Typed_value.Null;
     Typed_value.Array [Typed_value.Null, Typed_value.Null];
     Typed_value.Vec [Typed_value.Null]; Typed_value.Keyset [Typed_value.Null];
     Typed_value.Dict [Typed_value.Null, Typed_value.Null]] |> rand_elt in
  let module HTC = Hhas_type_constraint in
  let mutate_flag (f : HTC.type_constraint_flag) : HTC.type_constraint_flag =
    if not (should_mutate()) then f else
    [HTC.Nullable; HTC.HHType; HTC.ExtendedHint;
     HTC.TypeVar;  HTC.Soft;   HTC.TypeConstant] |> rand_elt in
  let mutate_constraint (const : HTC.t) : HTC.t =
    HTC.make
      (const |> HTC.name  |> mutate_option)
      (const |> HTC.flags |> delete_map mutate_flag) in
  let mutate_type_info (info : Hhas_type_info.t) : Hhas_type_info.t =
    Hhas_type_info.make
      (info |> Hhas_type_info.user_type       |> mutate_option)
      (info |> Hhas_type_info.type_constraint |> mutate_constraint) in
  let mutate_attribute (att : Hhas_attribute.t) : Hhas_attribute.t =
    Hhas_attribute.make
      (att |> Hhas_attribute.name)
      (att |> Hhas_attribute.arguments |> delete_map mutate_typed_value) in
  let mutate_param (param : Hhas_param.t) : Hhas_param.t =
    Hhas_param.make
      (param |> Hhas_param.name)
      (param |> Hhas_param.is_reference |> mutate_bool)
      (param |> Hhas_param.is_variadic |> mutate_bool)
      (param |> Hhas_param.type_info |> option_lift mutate_type_info)
      (param |> Hhas_param.default_value) in
  let mutate_body_data (body : Hhas_body.t) : Hhas_body.t =
    let mutate_static_init (s, opt) = (s, mutate_option opt) in
    Hhas_body.make
      (body |> Hhas_body.instrs)
      (body |> Hhas_body.decl_vars)
      (body |> Hhas_body.num_iters)
      (body |> Hhas_body.num_cls_ref_slots  |> fun n -> mutate_int n !mag)
      (body |> Hhas_body.is_memoize_wrapper |> mutate_bool)
      (body |> Hhas_body.params             |> delete_map mutate_param)
      (body |> Hhas_body.return_type        |> option_lift mutate_type_info)
      (body |> Hhas_body.static_inits       |> delete_map mutate_static_init) in
  let mutate_class_data (ids : Hhbc_id.Class.t list) (cls : Hhas_class.t) =
    let module HC = Hhas_class in
    let mutate_cls_id (id : Hhbc_id.Class.t) : Hhbc_id.Class.t =
       if not (should_mutate()) then id else rand_elt ids in
    let mutate_method_data (m : Hhas_method.t) : Hhas_method.t =
      Hhas_method.make
        (m |> Hhas_method.attributes        |> delete_map mutate_attribute)
        (m |> Hhas_method.is_protected      |> mutate_bool)
        (m |> Hhas_method.is_public         |> mutate_bool)
        (m |> Hhas_method.is_private        |> mutate_bool)
        (m |> Hhas_method.is_static         |> mutate_bool)
        (m |> Hhas_method.is_final          |> mutate_bool)
        (m |> Hhas_method.is_abstract       |> mutate_bool)
        (m |> Hhas_method.no_injection      |> mutate_bool)
        (m |> Hhas_method.name)
        (m |> Hhas_method.body              |> mutate_body_data)
        (m |> Hhas_method.is_async          |> mutate_bool)
        (m |> Hhas_method.is_generator      |> mutate_bool)
        (m |> Hhas_method.is_pair_generator |> mutate_bool)
        (m |> Hhas_method.is_closure_body   |> mutate_bool) in
    let mutate_property (prop : Hhas_property.t) : Hhas_property.t =
      Hhas_property.make
        (prop |> Hhas_property.is_private         |> mutate_bool)
        (prop |> Hhas_property.is_protected       |> mutate_bool)
        (prop |> Hhas_property.is_public          |> mutate_bool)
        (prop |> Hhas_property.is_static          |> mutate_bool)
        (prop |> Hhas_property.is_deep_init       |> mutate_bool)
        (prop |> Hhas_property.no_serialize       |> mutate_bool)
        (prop |> Hhas_property.name)
        (prop |> Hhas_property.initial_value |> option_lift mutate_typed_value)
        (prop |> Hhas_property.initializer_instrs |> mutate_option)
        (prop |> Hhas_property.type_info |> mutate_type_info) in
    let mutate_constant (const : Hhas_constant.t) : Hhas_constant.t =
      Hhas_constant.make
        (const |> Hhas_constant.name)
        (const |> Hhas_constant.value |> option_lift mutate_typed_value)
        (const |> Hhas_constant.initializer_instrs |> mutate_option) in
    let mutate_typed_constant (const : Hhas_type_constant.t) =
      Hhas_type_constant.make
        (const |> Hhas_type_constant.name)
        (const |> Hhas_type_constant.initializer_t
                                          |> option_lift mutate_typed_value) in
    let mutate_req ((trait, str) as pair) =
      if not (should_mutate()) then pair else
      match trait with
      | Ast.MustExtend -> Ast.MustImplement, str
      | Ast.MustImplement -> Ast.MustExtend, str in
    HC.make
      (cls |> HC.attributes         |> delete_map mutate_attribute)
      (cls |> HC.base               |> option_lift mutate_cls_id)
      (cls |> HC.implements         |> delete_map mutate_cls_id)
      (cls |> HC.name)
      (cls |> HC.is_final           |> mutate_bool)
      (cls |> HC.is_abstract        |> mutate_bool)
      (cls |> HC.is_interface       |> mutate_bool)
      (cls |> HC.is_trait           |> mutate_bool)
      (cls |> HC.is_xhp             |> mutate_bool)
      (cls |> HC.is_top             |> mutate_bool)
      (cls |> HC.class_uses)
      (cls |> HC.class_use_aliases)
      (cls |> HC.enum_type          |> option_lift mutate_type_info)
      (cls |> HC.methods            |> delete_map mutate_method_data)
      (cls |> HC.properties         |> delete_map mutate_property)
      (cls |> HC.constants          |> delete_map mutate_constant)
      (cls |> HC.type_constants     |> delete_map mutate_typed_constant)
      (cls |> HC.requirements       |> delete_map mutate_req) in
  let mutate_fun_data (f : Hhas_function.t) : Hhas_function.t =
    Hhas_function.make
      (f |> Hhas_function.attributes        |> delete_map mutate_attribute)
      (f |> Hhas_function.name)
      (f |> Hhas_function.body              |> mutate_body_data)
      (f |> Hhas_function.is_async          |> mutate_bool)
      (f |> Hhas_function.is_generator      |> mutate_bool)
      (f |> Hhas_function.is_pair_generator |> mutate_bool)
      (f |> Hhas_function.is_top            |> mutate_bool) in
  let mutate_typedef (typedef : Hhas_typedef.t) : Hhas_typedef.t =
    Hhas_typedef.make
      (typedef |> Hhas_typedef.name)
      (typedef |> Hhas_typedef.type_info      |> mutate_type_info)
      (typedef |> Hhas_typedef.type_structure |>
                                            option_lift mutate_typed_value) in
  let mut_data (prog : HP.t) : HP.t =
    let ids = prog |> HP.classes |> delete_map Hhas_class.name in
    HP.make
      (prog |> HP.adata)
      (prog |> HP.functions |> delete_map mutate_fun_data)
      (prog |> HP.classes   |> delete_map (mutate_class_data ids))
      (prog |> HP.typedefs  |> delete_map mutate_typedef)
      (prog |> HP.main      |> mutate_body_data) in
  let open Nondet in
  Instr_utils.num_fold
    (fun a -> mut_data input |> add_event a) !metadata_reps (return input)

(*---------------------------------Execution----------------------------------*)

open Nondet

let fuzz (input : HP.t) (mutations : mutation list): unit =
  mutations |> List.fold_left (>>=) (return input) >>| print_output |> ignore

(* command line driver *)
let _ =
  Random.self_init ();
  if ! Sys.interactive then ()
  else
    set_binary_mode_out stdout true;
    let input = read_input () in
    let mutations = [mutate_immediate; mutate_duplicate; mutate_reorder;
                     mutate_remove;    (*mutate_replace;   mutate_insert *)
                     mutate_metadata] in
    if (!complete_reps > 0)
    then (imm_reps := 1; dup_reps := 1; reorder_reps := 1; remove_reps := 1;
         replace_reps := 1; insert_reps := 1; metadata_reps := 1)
    else complete_reps := 1;
    for n = 1 to !complete_reps do
      fuzz input mutations
    done
