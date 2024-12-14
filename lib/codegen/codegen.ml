open Core.Ast

module Env = Map.Make(String)

let out_dir = "while_programs"

let program_start = {|
.class public XXX.XXX
.super java/lang/Object

.method public static write(I)V 
    .limit locals 1 
    .limit stack 2 
    getstatic java/lang/System/out Ljava/io/PrintStream; 
    iload 0
    invokevirtual java/io/PrintStream/println(I)V   
    return 
.end method

.method public static main([Ljava/lang/String;)V
   .limit locals 200
   .limit stack 200

; COMPILED CODE STARTS   

|}

let library_start = {|

|}

let label_counter = ref 0

let new_label (s: string) =
  incr label_counter;
  Printf.sprintf "%s_%n" s !label_counter

let fmtl l = 
  Printf.sprintf "%s:\n" l

let fmt (operator) (operand) =
  Printf.sprintf "\t%s %s\n" operator operand


let map_size map =
  Env.fold (fun _ _ acc -> acc + 1) map 0

let c_bop (op: bcomp): string = 
  let op_str = match op with
  | EQ -> "ne "
  | NE -> "eq "
  | GT -> "le "
  | LT -> "ge "
  | GE -> "lt "
  | LE -> "gt " in
  "\tif_icmp" ^ op_str

let c_aop (a: aop) =
  match a with
  | SUB -> "\tisub\n"
  | ADD -> "\tiadd\n"
  | MULT -> "\timul\n"
  | DIV -> "\tidiv\n"
  | MOD -> "\tirem\n"


let rec c_stmt (st: stmt) (env: int Env.t): string * int Env.t = 
  match st with 
  | SKIP -> "", env
  | SEQ_STMT(st1, st2) -> 
    let (instr1, env1) = c_stmt st1 env in
    let (instr2, env2) = c_stmt st2 env1 in
    (instr1 ^ instr2, env2)
  | IF(b, s1, s2) -> 
    let ifelse = new_label "Ifelse" in
    let endif = new_label "Endif" in 
    let (cs1, env1) = c_stmt s1 env in
    let (cs2, env2) = c_stmt s2 env1 in
      (c_bexp b env) ^
      (fmt "ifeq" ifelse) ^(* if our bexp evaluated to false, jump to else *)
      (cs1) ^
      (fmt "goto" endif) ^ (* we executed the 'then' branch, jump to end*)
      (fmtl ifelse) ^
      (cs2) ^
      (fmtl endif), env2
  | WHILE(b, s1) ->
    let (cs1, env1) = c_stmt s1 env in
    let l_whl = new_label "Startwhile" in
    let l_brk = new_label "Endwhile" in
      (fmtl l_whl) ^
      (c_bexp b env) ^
      (fmt "ifeq" l_brk) ^ (* if our bexp resolved to 0, break *)
      (cs1) ^
      (fmt "goto" l_whl) ^
      (fmtl l_brk), env1
  | ASSIGN(id, e1) ->
    let ce1 = c_aexp e1 env in
    let (idx, env1) = if Env.mem id env 
      then (Env.find id env, env) 
      else 
        let new_variable = map_size env in 
        let env1 = Env.add id new_variable env in
        (new_variable, env1)
      in
    (ce1) ^
    (fmt "istore" (string_of_int idx)), env1
  | WRITE(id) -> 
    let idx = Env.find id env |> string_of_int in
    (fmt "iload" idx) ^
    "\tinvokestatic XXX/XXX/write(I)V\n", env
  | _ -> failwith "Not implemented"


and c_bexp (bex: bexp) (env: int Env.t) : string = 
    match bex with
    | TRUE -> "i_const0\n"
    | FALSE -> "i_const0\n"
    | COMP(op, e1, e2) ->
      let instr1 = c_aexp e1 env in
      let instr2 = c_aexp e2 env in
      let comp_f = new_label "Comp_f" in
      let comp_end = new_label "Comp_end" in
      instr1 ^ 
      instr2 ^ 
      ((c_bop op) ^ comp_f) ^
      "\n\tldc 1\n" ^
      (fmt "goto" comp_end) ^
      (fmtl comp_f) ^
      ("\tldc 0\n") ^  
      (fmtl comp_end)
    | BEXP(bop, bexp1, bexp2) -> 
      begin
        match bop with
        | CONJ ->
          let l_false = new_label "Conj_false" in
          let l_end = new_label "Conj_end" in
          (c_bexp bexp1 env) ^ 
          (fmt "ifeq" l_false) ^ (* if first term is false, shortcut, push 0 and exit *)
          (c_bexp bexp2 env) ^ 
          (fmt "goto" l_end) ^   (* bexp1 was true, so result is result of bexp2 *)
          (fmtl l_false) ^       (* restate 0 and exit *)
          ("\ticonst_0\n") ^
          (fmtl l_end)
        | DISJ ->
          let l_true = new_label "Disj_true" in
          let l_end = new_label "Disj_end" in
          (c_bexp bexp1 env) ^
          (fmt "ifne" l_true) ^
          (c_bexp bexp2 env) ^
          (fmt "goto" l_end) ^
          (fmtl l_true) ^
          ("\tldc 1\n") ^
          (fmtl l_end)
        | BEQ -> 
          (c_bexp bexp1 env) ^
          (c_bexp bexp2 env) ^
          "\teq\n"
        | BNE ->
          (c_bexp bexp1 env) ^
          (c_bexp bexp2 env) ^
          "\tneq\n"
      end
  


and c_aexp (exp : aexp) (env: int Env.t) : string =
  match exp with
  | VAL(n) -> (fmt "ldc" (string_of_int n))
  | VAR(id) -> 
    let loc = Env.find id env in
    (fmt "iload" (string_of_int loc))
  | EXPR(aop, e1, e2) ->
    let instr1 = c_aexp e1 env in
    let instr2 = c_aexp e2 env in
      instr1 ^ instr2 ^ (c_aop aop)


let f_write str f_name = 
  let oc = open_out f_name in
  output_string oc str;
  close_out oc


let compile sstmt class_name = 
  let env = Env.empty in
  let (instr, _) = (c_stmt sstmt env) in
  let prog =
    Printf.sprintf "%s\n%s\n\treturn\n.end method" 
      program_start
      instr in
  
  let compiled =
    let pattern = Re.Perl.compile_pat "XXX" in
    Re.replace_string ~all:true ~by:class_name pattern prog in
  
  f_write compiled (Printf.sprintf "%s/%s.j" out_dir class_name)