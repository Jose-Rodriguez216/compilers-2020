open Printf
open Int64

type binop = Plus | Minus | Mult
   
type expr =
  | Num of int64
  | Add1 of expr
  | Sub1 of expr
  | BinOp of expr * binop * expr
  | Id of string
  | Let of string * expr * expr
  | If of expr * expr * expr

type reg = 
  | RSP                         (* Stack pointer *)
  | RAX
  | RBX

type arg = 
  | Const of int64
  | Reg of reg
  | RegOffset of reg * int (* RegOffset(reg, i) represents address [reg + 8*i] *)

type instruction =
  | IMov of arg * arg
  | IAdd of arg * arg
  | ICmp of arg * arg
  | IJe of string
  | ILabel of string
  | IJump of string

type env = (string * int) list

let reg_to_string reg =
  match reg with
  | RAX -> "RAX"
  | RSP -> "RSP"
  | RBX -> "RBX"

let arg_to_string arg =
  match arg with
  | Const n -> Int64.to_string n
  | Reg reg -> reg_to_string reg
  | RegOffset (reg, off) -> "[" ^ (reg_to_string reg) ^ " + 8*" ^ (string_of_int off) ^ "]"

let rec asm_to_string (asm : instruction list) : string =
  (* les toca a ustedes *)
  match asm with
  | [] -> ""
  | IMov (arg1, arg2)::tail -> "mov " ^ arg_to_string arg1 ^ ", " ^ arg_to_string arg2 ^ "\n" ^ asm_to_string tail
  | IAdd (arg1, arg2)::tail -> "add "  ^ arg_to_string arg1 ^ ", " ^ arg_to_string arg2 ^ "\n" ^ asm_to_string tail
  | ICmp (arg1, arg2)::tail -> "cmp " ^ arg_to_string arg1 ^ ", " ^ arg_to_string arg2 ^ "\n" ^ asm_to_string tail
  | IJe label::tail -> "je " ^ label ^ "\n" ^ asm_to_string tail
  | ILabel label::tail -> label ^ ":\n" ^ asm_to_string tail
  | IJump label::tail -> "jmp " ^ label ^ "\n" ^ asm_to_string tail

let rec lookup name env =
  match env with
  | [] -> failwith (sprintf "Identifier %s not found in environment" name)
  | (n, i)::rest ->
     if name = n then i else (lookup name rest)
;;

let add name env =
  let slot = 1 + (List.length env) in
  ((name,slot)::env, slot)
;;

let gensym =
  let counter = ref 0 in
  (fun basename ->
    counter := !counter + 1;
    sprintf "%s_%d" basename !counter);;

let is_imm e =
  match e with
  | Num _ -> true
  | Id _ -> true
  | _ -> false

let rec is_anf e =
  match e with
  | Add1 e -> is_imm e
  | Sub1 e -> is_imm e
  | BinOp (e1, _, e2) -> is_imm e1 && is_imm e2
  | Let (_, e1, e2) -> is_anf e1 && is_anf e2
  | If (cond, thn, els) -> is_imm cond && is_anf thn && is_anf els
  | _ -> is_imm e 

let rec anf_v1 e =
  match e with
  | Add1 e1 ->
    let (e1_ans, e1_context) = anf_v1 e1 in
    let temp = gensym "add1" in
    (Id(temp), (* the answer *)
     e1_context @ (* the context needed for the left answer to make sense *)
     [(temp, Add1(e1_ans))]) (* definition of the answer *)
  | BinOp (e1, op, e2) ->
     let (left_ans, left_context) = anf_v1 e1 in
     let (right_ans, right_context) = anf_v1 e2 in
     let temp = gensym "binop" in
       (Id(temp), left_context @ right_context @ [(temp, BinOp (left_ans, op, right_ans))])
  | If (con, thn, els) ->
     let (con_ans, con_context) = anf_v1 con in
     let (thn_ans, thn_context) = anf_v1 thn in
     let (els_ans, els_context) = anf_v1 els in
     let cond_tmp = gensym "cond" in
      (Let (cond_tmp, con_ans, If (Id cond_tmp, thn_ans, els_ans) ),
       thn_context @
       els_context @
       con_context)
(* if 3 - 2: 1 else 2  -> let cond_1 = 3 -2 in if cond_1:  1 else 2 *)
  | Num _ -> (e, [])

let rec anf_helper e context =
  match context with
  | [] -> e
  | (id, e2) :: tail -> Let (id, e2, anf_helper e tail)

let anf (e : expr) : expr =
  let (e, context ) = anf_v1 e in
    anf_helper e context

(* compile is responsible for compiling just a single expression,
   and does not care about the surrounding scaffolding *)
let rec compile (e : expr) (env : env) : instruction list =
  match e with
  | Num n -> [ IMov(Reg(RAX), Const(n)) ]
  | Add1 e -> (compile e env) @ [ IAdd(Reg(RAX), Const (1L)) ]  
  | Sub1 e -> (compile e env) @ [ IAdd(Reg(RAX), Const (-1L)) ]
  | BinOp (e1, Plus, e2) ->
     (compile e1 env) @
     [ IMov (Reg(RBX), Reg(RAX))] @ (* guardarlo *)
     (compile e2 env) @
     [ IAdd (Reg(RAX), Reg(RBX))]   (* sumar - cuidado con orden argumentos *)
  | Id name -> let slot = (lookup name env) in
               [ IMov(Reg(RAX), RegOffset(RSP, ~-1 * slot) ) ]
  | Let (x, e, b) ->
     let (env', slot) = add x env in
     (* Compile the binding, and get the result into RAX *)
     (compile e env)
     (* Copy the result in RAX into the appropriate stack slot *)
     @ [ IMov(RegOffset(RSP, ~-1 * slot), Reg(RAX)) ]
     (* Compile the body, given that x is in the correct slot when it's needed *)
     @ (compile b env')
  | If (e1, e2, e3) ->
     let else_label = gensym "else_branch" in
     let done_label = gensym "done" in
     compile e1 env
     @ [ ICmp (Reg(RAX), Const(0L)) ;
         IJe (else_label) ] @
       compile e2 env
       @ [ IJump done_label ]
       @ [ ILabel else_label ]
       @ compile e3 env
       @ [ ILabel done_label ]

(* compile_prog surrounds a compiled program by whatever scaffolding is needed *)
let compile_prog (e : expr) : string =
  (* compile the program *)
  let instrs = compile e [] in
  (* convert it to a textual form *)
  let asm_string = asm_to_string instrs in
  (* surround it with the necessary scaffolding *)
  let prelude = "
section .text
global our_code_starts_here
our_code_starts_here:" in
  let suffix = "ret" in
  prelude ^ "\n" ^ asm_string ^ "\n" ^ suffix
  ;;

(* Some OCaml boilerplate for reading files and command-line arguments *)

(* need a real parser now!
let () =
  let input_file = (open_in (Sys.argv.(1))) in
  let input_program = Int64.of_string (input_line input_file) in
  let program = (compile_prog input_program) in
  printf "%s\n" program;;
*)
