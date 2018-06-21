Set Universe Polymorphism.
Unset Universe Minimization ToSet.
(* TODO: should we do this? *)
Set Primitive Projections.
Unset Printing Primitive Projection Parameters.
Set Printing Projections.

Require compiler.Common.

Local Notation "'bind_Some' x <- a ; f" :=
  (match a with
   | Some x => f
   | None => None
   end)
    (right associativity, at level 60, x pattern).

Module Imp. (* TODO: file *)

Record ImpParameters :=
  {
    mword : Type;
    mword_nonzero : mword -> bool;

    varname : Type;
    funname : Type;
    actname : Type;
    bopname : Type;
    mem : Type;

    varmap : Type;
    varmap_operations : Common.Map varmap varname mword;

    interp_binop : bopname -> mword -> mword -> mword;
    load : mword -> mem -> option mword;
    store : mword -> mword -> mem -> option mem;
  }.

Section Imp.
  Context {p : ImpParameters}.
  (* RecordImport p (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
  Local Notation mword := p.(mword).
  Local Notation mword_nonzero := p.(mword_nonzero).
  Local Notation varname := p.(varname).
  Local Notation funname := p.(funname).
  Local Notation actname := p.(actname).
  Local Notation bopname := p.(bopname).
  Local Notation varmap := p.(varmap).
  Local Notation mem := p.(mem).
  Local Definition varmap_operations_ : Common.Map _ _ _ := p.(varmap_operations). Global Existing Instance varmap_operations_.
  Local Notation interp_binop := p.(interp_binop).
  Local Notation load := p.(load).
  Local Notation store := p.(store).

  Record ImpInterface :=
    {
      expr : Type;
      ELit : mword -> expr;
      EVar : varname -> expr;
      EOp : bopname -> expr -> expr -> expr;

      stmt : Type;

      SLoad : varname -> expr -> stmt;
      SStore : expr -> expr -> stmt;
      SSet : varname -> expr -> stmt;
      SIf : expr -> stmt -> stmt -> stmt;
      SWhile : expr -> stmt -> stmt;
      SSeq : stmt -> stmt -> stmt;
      SSkip : stmt;
      SCall : list varname -> funname -> list expr -> stmt;
      SIO : list varname -> actname -> list expr -> stmt;

      cont : Type -> Type;
      CSuspended : forall T, T -> cont T;
      CSeq : forall T, cont T -> stmt -> cont T;
      CStack : forall T, varmap -> cont T -> list varname -> list varname -> cont T;

      ioact : Type;
      ioret : Type;

      interp_expr : forall (st: varmap)(e: expr), option (mword);
      interp_stmt : forall (lookupFunction : funname -> option (list varname * list varname * stmt))(f: nat)(st: varmap)(m: mem)(s: stmt),       option (varmap*mem*option(cont ioact));
      interp_cont : forall (lookupFunction : funname -> option (list varname * list varname * stmt))(f: nat)(st: varmap)(m: mem)(s: cont ioret), option (varmap*mem*option(cont ioact));
    }.

  Local Inductive _expr :=
  | _ELit(v: mword)
  | _EVar(x: varname)
  | _EOp(op: bopname) (e1 e2: _expr).

  Local Inductive _stmt :=
  | _SLoad(x: varname) (addr: _expr)
  | _SStore(addr val: _expr)
  | _SSet(x: varname)(e: _expr)
  | _SIf(cond: _expr)(bThen bElse: _stmt)
  | _SWhile(cond: _expr)(body: _stmt)
  | _SSeq(s1 s2: _stmt)
  | _SSkip
  | _SCall(binds: list varname)(f: funname)(args: list _expr)
  | _SIO(binds: list varname)(io : actname)(args: list _expr).

  Local Fixpoint _interp_expr(st: varmap)(e: _expr): option (mword) :=
    match e with
    | _ELit v => Some v
    | _EVar x => Common.get st x
    | _EOp op e1 e2 =>
        bind_Some v1 <- _interp_expr st e1;
        bind_Some v2 <- _interp_expr st e2;
        Some (interp_binop op v1 v2)
    end.

  Section cont.
    Context {T : Type}.
    Local Inductive _cont : Type :=
    | _CSuspended(_:T)
    | _CSeq(s1:_cont) (s2: _stmt)
    | _CStack(st: varmap)(c: _cont)(binds rets: list varname).
  End cont. Arguments _cont : clear implicits.

  Local Definition _ioact : Type := (list varname * actname * list mword).
  Local Definition _ioret : Type := (list varname * list mword).
  
  Section WithFunctions.
    Context (lookupFunction : funname -> option (list varname * list varname * _stmt)).
    Local Fixpoint _interp_stmt(f: nat)(st: varmap)(m: mem)(s: _stmt): option (varmap*mem*option(_cont _ioact)) :=
      match f with
      | 0 => None (* out of fuel *)
      | S f => match s with
        | _SLoad x a =>
            bind_Some a <- _interp_expr st a;
            bind_Some v <- load a m;
            Some (Common.put st x v, m, None)
        | _SStore a v =>
            bind_Some a <- _interp_expr st a;
            bind_Some v <- _interp_expr st v;
            bind_Some m <- store a v m;
            Some (st, m, None)
        | _SSet x e =>
            bind_Some v <- _interp_expr st e;
            Some (Common.put st x v, m, None)
        | _SIf cond bThen bElse =>
            bind_Some v <- _interp_expr st cond;
            _interp_stmt f st m (if mword_nonzero v then bThen else bElse)
        | _SWhile cond body =>
            bind_Some v <- _interp_expr st cond;
            if mword_nonzero v
            then
              bind_Some (st, m, c) <- _interp_stmt f st m body;
              match c with
              | Some c => Some (st, m, Some (_CSeq c (_SWhile cond body)))
              | None => _interp_stmt f st m (_SWhile cond body)
              end
            else Some (st, m, None)
        | _SSeq s1 s2 =>
            bind_Some (st, m, c) <- _interp_stmt f st m s1;
            match c with
            | Some c => Some (st, m, Some (_CSeq c s2))
            | None => _interp_stmt f st m s2
            end
        | _SSkip => Some (st, m, None)
        | _SCall binds fname args =>
          bind_Some (params, rets, fbody) <- lookupFunction fname;
          bind_Some argvs <- Common.option_all (List.map (_interp_expr st) args);
          bind_Some st0 <- Common.putmany params argvs Common.empty;
          bind_Some (st1, m', oc) <- _interp_stmt f st0 m fbody;
          match oc with
          | Some c => Some (st, m', Some (_CStack st1 c binds rets))
          | None => 
            bind_Some retvs <- Common.option_all (List.map (Common.get st1) rets);
            bind_Some st' <- Common.putmany binds retvs st;
            Some (st', m', None)
          end
        | _SIO binds ionum args =>
          bind_Some argvs <- Common.option_all (List.map (_interp_expr st) args);
          Some (st, m, Some (_CSuspended (binds, ionum, argvs)))
        end
      end.

    Local Fixpoint _interp_cont(f: nat)(st: varmap)(m: mem)(s: _cont _ioret): option (varmap*mem*option(_cont _ioact)) :=
      match f with
      | 0 => None (* out of fuel *)
      | S f => match s with
        | _CSuspended (binds, retvs) =>
            bind_Some st' <- Common.putmany binds retvs st;
            Some (st', m, None)
        | _CSeq c s2 =>
            bind_Some (st, m, oc) <- _interp_cont f st m c;
            match oc with
            | Some c => Some (st, m, Some (_CSeq c s2))
            | None => _interp_stmt f st m s2
            end
        | _CStack stf cf binds rets =>
          bind_Some (stf', m', oc) <- _interp_cont f stf m cf;
          match oc with
          | Some c => Some (st, m', Some (_CStack stf' c binds rets))
          | None => 
            bind_Some retvs <- Common.option_all (List.map (Common.get stf') rets);
            bind_Some st' <- Common.putmany binds retvs st;
            Some (st', m', None)
          end
        end
      end.
  End WithFunctions.

  Definition Imp : ImpInterface :=
        {|
          ELit := _ELit;
          EVar := _EVar;
          EOp := _EOp;

          SLoad := _SLoad;
          SStore := _SStore;
          SSet := _SSet;
          SIf := _SIf;
          SWhile := _SWhile;
          SSeq := _SSeq;
          SSkip := _SSkip;
          SCall := _SCall;
          SIO := _SIO;

          CSuspended := @_CSuspended;
          CSeq := @_CSeq;
          CStack := @_CStack;

          interp_expr := _interp_expr;
          interp_stmt := _interp_stmt;
          interp_cont := _interp_cont;
        |}.
End Imp.
Arguments ImpInterface : clear implicits.
Arguments Imp : clear implicits.

End Imp. (* TODO: file *)



Require riscv.util.BitWidths.
Require compiler.Memory.
Require compiler.Op.

Module RISCVImp. (* TODO: file *)

Record RISCVImpParameters :=
  {
    bw : riscv.util.BitWidths.BitWidths;
    varname : Type;
    funname : Type;
    actname : Type;
    varmap : Type;
    varmap_operations : Common.Map varmap varname (bbv.Word.word (riscv.util.BitWidths.wXLEN));
  }.

Definition ImpParameters_of_RISCVImpParameters (p:RISCVImpParameters): Imp.ImpParameters :=
  {|
    Imp.mword := bbv.Word.word (@riscv.util.BitWidths.wXLEN p.(bw));
    Imp.mword_nonzero := fun v => if bbv.Word.weq v (bbv.Word.wzero _) then false else true;
    Imp.varname := p.(varname);
    Imp.funname := p.(funname);
    Imp.actname := p.(actname);
    Imp.bopname := compiler.Op.binop;
    Imp.mem := compiler.Memory.mem;

    Imp.interp_binop := compiler.Op.eval_binop;
    Imp.load := Memory.read_mem;
    Imp.store := Memory.write_mem;

    Imp.varmap := p.(varmap);
    Imp.varmap_operations := p.(varmap_operations);
  |}.
Definition RISCVImp (p:RISCVImpParameters) : Imp.ImpInterface (ImpParameters_of_RISCVImpParameters p)
  := Imp.Imp (ImpParameters_of_RISCVImpParameters p).
End RISCVImp. (* TODO: file *)



Require Import compiler.Common.
Require Import Coq.Lists.List.
Import ListNotations.
Require Import lib.LibTacticsMin.
Require Import riscv.util.BitWidths.
Require Import compiler.Tactics.
Require Import compiler.Op.
Require Import compiler.StateCalculus.
Require Import bbv.DepEqNat.
Require Import compiler.NameWithEq.
Require Import Coq.Program.Tactics.
Require Import compiler.Memory.

Module ImpInversion. (* TODO: file*)
Section ImpInversion.
  Import Imp.
  Context (p:ImpParameters).
  Let Imp : Imp.ImpInterface p := Imp.Imp p.
  (* RecordImport p (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
  Local Notation mword := p.(mword).
  Local Notation mword_nonzero := p.(mword_nonzero).
  Local Notation varname := p.(varname).
  Local Notation funname := p.(funname).
  Local Notation actname := p.(actname).
  Local Notation bopname := p.(bopname).
  Local Notation varmap := p.(varmap).
  Local Notation mem := p.(mem).
  Local Notation interp_binop := p.(interp_binop).
  Local Notation load := p.(load).
  Local Notation store := p.(store).
  (* RecordImport Imp (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
  Local Notation expr := Imp.(expr).
  Local Notation stmt := Imp.(stmt).
  Local Notation cont := Imp.(cont).
  Local Notation interp_expr := Imp.(interp_expr).
  Local Notation interp_stmt := Imp.(interp_stmt).
  Local Notation interp_cont := Imp.(interp_cont).
  
  Lemma cont_uninhabited (T:Set) (_:T -> False) (X : cont T) : False. Proof. induction X; auto 2. Qed.
  Fixpoint lift_cont {A B : Set} (P : A -> B -> Prop) (a : cont A) (b : cont B) {struct a} :=
    match a, b with
    | _CSuspended a, _CSuspended b =>
      P a b
    | _CSeq a sa, _CSeq b sb =>
      lift_cont P a b /\ sa = sb
    | _CStack sta a ba ra, _CStack stb b bb rb =>
      (forall v, Common.get sta v = Common.get stb v) /\ lift_cont P a b /\ ba = bb /\ ra = rb
    | _, _ => False
    end.

  Fixpoint expr_size(e: expr): nat :=
    match e with
    | _ELit _ => 8
    | _EVar _ => 1
    | _EOp op e1 e2 => S (S (expr_size e1 + expr_size e2))
    end.

  Fixpoint stmt_size(s: stmt): nat :=
    match s with
    | _SLoad x a => S (expr_size a)
    | _SStore a v => S (expr_size a + expr_size v)
    | _SSet x e => S (expr_size e)
    | _SIf cond bThen bElse => S (expr_size cond + stmt_size bThen + stmt_size bElse)
    | _SWhile cond body => S (expr_size cond + stmt_size body)
    | _SSeq s1 s2 => S (stmt_size s1 + stmt_size s2)
    | _SSkip => 1
    | _SCall binds _ args | _SIO binds _ args =>
                           S (length binds + length args + List.fold_right Nat.add O (List.map expr_size args))
    end.

  Local Ltac inversion_lemma :=
    intros;
    simpl in *;
    repeat (destruct_one_match_hyp; try discriminate);
    inversionss;
    eauto 99.

  Lemma invert_interp_SLoad: forall env fuel initialSt initialM x e final,
      interp_stmt env (S fuel) initialSt initialM (SLoad _ x e) = Some final ->
      exists a v, interp_expr initialSt e = Some a /\
                  load a initialM = Some v /\
                  final = (put initialSt x v, initialM, None).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SStore: forall env fuel initialSt initialM a v final,
    interp_stmt env (S fuel) initialSt initialM (SStore _ a v) = Some final ->
    exists av vv finalM, interp_expr initialSt a = Some av /\
                         interp_expr initialSt v = Some vv /\
                         store av vv initialM = Some finalM /\
                         final = (initialSt, finalM, None).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SSet: forall env f st1 m1 p2 x e,
    interp_stmt env (S f) st1 m1 (SSet _ x e) = Some p2 ->
    exists v, interp_expr st1 e = Some v /\ p2 = (put st1 x v, m1, None).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SIf: forall env f st1 m1 p2 cond bThen bElse,
    interp_stmt env (S f) st1 m1 (SIf _ cond bThen bElse) = Some p2 ->
    exists cv,
      interp_expr st1 cond = Some cv /\ 
      (mword_nonzero cv = true /\ interp_stmt env f st1 m1 bThen = Some p2 \/
       mword_nonzero cv = false /\ interp_stmt env f st1 m1 bElse = Some p2).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SSkip: forall env st1 m1 p2 f,
    interp_stmt env (S f) st1 m1 (SSkip _) = Some p2 ->
    p2 = (st1, m1, None).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SSeq: forall env st1 m1 p3 f s1 s2,
    interp_stmt env (S f) st1 m1 (SSeq _ s1 s2) = Some p3 ->
    exists st2 m2 oc, interp_stmt env f st1 m1 s1 = Some (st2, m2, oc) /\ (
        (oc = None /\ interp_stmt env f st2 m2 s2 = Some p3)
     \/ (exists c, oc = Some c /\ p3 = (st2, m2, Some (CSeq _ _ c s2)))).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SWhile: forall env st1 m1 p3 f cond body,
    interp_stmt env (S f) st1 m1 (SWhile _ cond body) = Some p3 ->
    exists cv,
      interp_expr st1 cond = Some cv /\
      (mword_nonzero cv = true /\
       (exists st2 m2 oc, interp_stmt env f st1 m1 body = Some (st2, m2, oc) /\ (
              ( oc = None /\ interp_stmt env f st2 m2 (SWhile _ cond body) = Some p3)
           \/ ( exists c, oc = Some c /\ p3 = (st2, m2, Some (CSeq _ _ c (SWhile _ cond body))))))
       \/ mword_nonzero cv = false /\ p3 = (st1, m1, None)).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SCall : forall env st m1 p2 f binds fname args,
    interp_stmt env (S f) st m1 (SCall _ binds fname args) = Some p2 ->
    exists params rets fbody argvs st0 st1 m' oc,
      env fname = Some (params, rets, fbody) /\
      option_all (map (interp_expr st) args) = Some argvs /\
      putmany params argvs empty = Some st0 /\
      interp_stmt env f st0 m1 fbody = Some (st1, m', oc) /\ (
       ( oc = None /\ exists retvs st',
         option_all (map (get st1) rets) = Some retvs /\
         putmany binds retvs st = Some st' /\
         p2 = (st', m', None)
       ) \/
       ( exists c, oc = Some c /\
         p2 = (st, m', Some (CStack _ _ st1 c binds rets)) ) ).
  Proof. inversion_lemma. Qed.

  Lemma invert_interp_SIO : forall env st m1 p2 f binds ioname args,
    interp_stmt env (S f) st m1 (SIO _ binds ioname args) = Some p2 ->
    exists argvs, option_all (map (Imp.interp_expr _ st) args) = Some argvs /\
                  p2 = (st, m1, Some (CSuspended _ _ (binds, ioname, argvs))).
  Proof. inversion_lemma. Qed.
End ImpInversion.

Local Tactic Notation "marker" ident(s) := let x := fresh s in pose proof tt as x; move x at top.
Ltac invert_interp_stmt :=
  lazymatch goal with
  | E: Imp.interp_stmt _ _ (S ?fuel) _ _ ?s = Some _ |- _ =>
    destruct s;
    [ apply invert_interp_SLoad in E; deep_destruct E; marker SLoad
    | apply invert_interp_SStore in E; deep_destruct E; marker SStore
    | apply invert_interp_SSet in E; deep_destruct E; marker SSet
    | apply invert_interp_SIf in E; deep_destruct E; [marker SIf_true | marker SIf_false]
    | apply invert_interp_SWhile in E; deep_destruct E; [marker SWhile_true | marker SWhile_blocked | marker SWhile_false ]
    | apply invert_interp_SSeq in E; deep_destruct E; [marker SSeq | marker SSeq_blocked ]
    | apply invert_interp_SSkip in E; deep_destruct E; marker SSkip
    | apply invert_interp_SCall in E; deep_destruct E; [marker SCall | marker SCall_blocked]
    | apply invert_interp_SIO in E; deep_destruct E; [marker SIO ]
    ] end.
End ImpInversion. (* TODO: file *)

Module ImpVars. (* TODO: file *)
Import ImpInversion.
Section ImpVars.
  Import Imp.
  Context {p:ImpParameters}.
  (* RecordImport p (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
  Local Notation mword := p.(mword).
  Local Notation mword_nonzero := p.(mword_nonzero).
  Local Notation varname := p.(varname).
  Local Notation funname := p.(funname).
  Local Notation actname := p.(actname).
  Local Notation bopname := p.(bopname).
  Local Notation varmap := p.(varmap).
  Local Notation mem := p.(mem).
  Local Notation interp_binop := p.(interp_binop).
  Local Notation load := p.(load).
  Local Notation store := p.(store).
  Let Imp : Imp.ImpInterface p := Imp.Imp p.
  (* RecordImport Imp (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
  Local Notation expr := Imp.(expr).
  Local Notation stmt := Imp.(stmt).
  Local Notation cont := Imp.(cont).
  Local Notation interp_expr := Imp.(interp_expr).
  Local Notation interp_stmt := Imp.(interp_stmt).
  Local Notation interp_cont := Imp.(interp_cont).

  (* TODO: record ImpParametersOK *)
  Context {mword_eq_dec : DecidableRel (@eq (Imp.varname p))}.

  (* Returns a list to make it obvious that it's a finite set. *)
  Fixpoint allVars_expr(e: expr): list varname :=
    match e with
    | _ELit v => []
    | _EVar x => [x]
    | _EOp op e1 e2 => (allVars_expr e1) ++ (allVars_expr e2)
    end.

  Fixpoint allVars_stmt(s: stmt): list varname := 
    match s with
    | _SLoad v e => v :: allVars_expr e
    | _SStore a e => (allVars_expr a) ++ (allVars_expr e)
    | _SSet v e => v :: allVars_expr e
    | _SIf c s1 s2 => (allVars_expr c) ++ (allVars_stmt s1) ++ (allVars_stmt s2)
    | _SWhile c body => (allVars_expr c) ++ (allVars_stmt body)
    | _SSeq s1 s2 => (allVars_stmt s1) ++ (allVars_stmt s2)
    | _SSkip => []
    | _SCall binds _ args | _SIO binds _ args => binds ++ List.fold_right (@List.app _) nil (List.map allVars_expr args)
    end.

  Context {set_varname: Type}.
  Context {varset: set set_varname varname}.

  (* Returns a static approximation of the set of modified vars.
     The returned set might be too big, but is guaranteed to include all modified vars. *)
  Fixpoint modVars(s: stmt): set_varname := 
    match s with
    | _SLoad v _ => singleton_set v
    | _SStore _ _ => empty_set
    | _SSet v _ => singleton_set v
    | _SIf _ s1 s2 => union (modVars s1) (modVars s2)
    | _SWhile _ body => modVars body
    | _SSeq s1 s2 => union (modVars s1) (modVars s2)
    | _SSkip => empty_set
    | _SCall binds _ _ | _SIO binds _ _ => of_list binds
    end.

  Ltac set_solver := set_solver_generic constr:(varname).
  
  Lemma modVars_subset_allVars: forall x s,
    x \in modVars s ->
    In x (allVars_stmt s).
  Proof.
    intros.
    induction s; simpl in *.
    { set_solver. }
    { set_solver. }
    { apply singleton_set_spec in H. auto. }
    { apply union_spec in H.
      apply in_or_app. right. apply in_or_app.
      destruct H as [H|H]; auto. }
    { apply in_or_app. right. auto. }
    { apply union_spec in H.
      apply in_or_app.
      destruct H as [H|H]; auto. }
    { eapply empty_set_spec. eassumption. }
    1,2 : generalize dependent binds; induction binds; intros H; cbn in *;
      [ apply empty_set_spec in H; destruct H
      | apply union_spec in H; destruct H;
        [ left; apply singleton_set_spec in H; auto
        | right; auto ] ].
  Qed.

  Ltac state_calc := state_calc_generic constr:(varname) constr:(mword).

  Lemma modVarsSound: forall env fuel s initialS initialM finalS finalM oc,
    interp_stmt env fuel initialS initialM s = Some (finalS, finalM, oc) ->
    only_differ initialS (modVars s) finalS.
  Proof.
    induction fuel; introv Ev.
    - discriminate.
    - invert_interp_stmt; cbn [modVars] in *; inversionss;
      repeat match goal with
      | IH: _, H: _ |- _ =>
          let IH' := fresh IH in pose proof IH as IH';
          specialize IH' with (1 := H);
          cbn [modVars] in IH';
          ensure_new IH'
      end.

      Focus 1.
      forget ((varset.(@singleton_set set_varname varname) x)) as xx.
      forget ((Imp.varmap_operations_.(@put varmap varname mword) initialS x v)) as y.
      clear IHfuel.
      revert env.
      repeat match goal with H : _ |- _ => clear H end.
      intros.
      Set Printing All.
      repeat match goal with H : _ |- _ => revert H end.

      Goal
         forall p : ImpParameters,
  let Imp : ImpInterface p := Imp.Imp p in
  forall (set_varname : Type) (varset : set set_varname (Imp.varname p)) (initialS : Imp.varmap p)
    (xx : set_varname) (y : Imp.varmap p)
    (_ : forall _ : Imp.funname p,
         option (prod (prod (list (Imp.varname p)) (list (Imp.varname p))) (@Imp.stmt _ Imp))),
  @only_differ (Imp.varname p) (Imp.mword p) (Imp.varmap p) (@Imp.varmap_operations_ p) set_varname varset
    initialS xx y.
        intros.
      congruence.

      (* SCall *)
      refine (only_differ_putmany _ _ _ _ _ _); eassumption.
  Qed.

End ImpVars.
End ImpVars. (* TODO: file *)


Require riscv.util.BitWidth32.
Module TestExprImp.
Import Imp compiler.Op.
Local Definition Imp := RISCVImp.RISCVImp {|
    RISCVImp.bw := riscv.util.BitWidth32.BitWidth32;
    RISCVImp.varname := Z;
    RISCVImp.funname := Empty_set;
    RISCVImp.actname := Empty_set;
  |}.

(*
given x, y, z

if y < x and z < x then
  c = x
  a = y
  b = z
else if x < y and z < y then
  c = y
  a = x
  b = z
else
  c = z
  a = x
  b = y
isRight = a*a + b*b == c*c
*)
Definition _a := 0%Z.
Definition _b := 1%Z.
Definition _c := 2%Z.
Definition _isRight := 3%Z.

(* RecordImport Imp (* COQBUG(https://github.com/coq/coq/issues/7808) *) *)
Local Notation expr := Imp.(_expr).
Local Notation stmt := Imp.(_stmt).
Local Notation cont := Imp.(_cont).
Local Notation interp_expr := Imp.(_interp_expr).
Local Notation interp_stmt := Imp.(_interp_stmt).
Local Notation interp_cont := Imp.(_interp_cont).

Eval cbn in
  (fun op : (RISCVImp.ImpParameters_of_RISCVImpParameters _).(bopname) =>
   (fun e1 e2 : expr => EOp op e1 e2) = (fun e1 e2 : expr => EOp op e1 e2)) OLt.

Eval cbn in
  (fun op : (RISCVImp.ImpParameters_of_RISCVImpParameters _).(bopname) =>
   (fun e1 e2 : expr => EOp op e1 e2) = (fun e1 e2 : expr => EOp op e1 e2)) OLt.

Eval cbn in (fun e1 e2 : Imp.expr => EOp OLt e1 e2) = (fun e1 e2 : Imp.expr => EOp OLt e1 e2).


Definition isRight(x y z: word 32) : stmt :=
  SSeq (SIf (EOp OAnd (EOp OLt (ELit y) (ELit x)) (EOp OLt (ELit z) (ELit x)))
            (SSeq (SSet _c (ELit x)) (SSeq (SSet _a (ELit y)) (SSet _b (ELit z))))
            ((SIf (EOp OAnd (EOp OLt (ELit x) (ELit y)) (EOp OLt (ELit z) (ELit y)))
                  (SSeq (SSet _c (ELit y)) (SSeq (SSet _a (ELit x)) (SSet _b (ELit z))))
                  (SSeq (SSet _c (ELit z)) (SSeq (SSet _a (ELit x)) (SSet _b (ELit y)))))))
       (SSet _isRight (EOp OEq (EOp OPlus (EOp OTimes (EVar _a) (EVar _a))
                                          (EOp OTimes (EVar _b) (EVar _b)))
                               (EOp OTimes (EVar _c) (EVar _c)))).

Definition run_isRight(x y z: word 32): option (word 32) :=
  final <- (interp_stmt empty 10 empty no_mem (isRight x y z));
  let '(finalSt, finalM) := final in
  get finalSt _isRight.

Goal run_isRight $3 $4 $5 = Some $1. reflexivity. Qed.
Goal run_isRight $3 $7 $5 = Some $0. reflexivity. Qed.
Goal run_isRight $4 $3 $5 = Some $1. reflexivity. Qed.
Goal run_isRight $5 $3 $5 = Some $0. reflexivity. Qed.
Goal run_isRight $5 $3 $4 = Some $1. reflexivity. Qed.
Goal run_isRight $12 $13 $5 = Some $1. reflexivity. Qed.

End TestExprImp.