From SegmentQueue.util Require Import
  everything local_updates big_opL cmra count_matching find_index.

Require Import SegmentQueue.lib.util.getAndSet.
Require Import SegmentQueue.lib.util.future.
From iris.heap_lang Require Import notation.
From SegmentQueue.lib.concurrent_linked_list.infinite_array
     Require Import array_spec iterator.iterator_impl.

Notation RESUMEDV := (InjLV #0).
Notation CANCELLEDV := (InjLV #1).
Notation BROKENV := (InjLV #2).
Notation TAKENV := (InjLV #3).
Notation REFUSEDV := (InjLV #4).

Section impl.

Variable array_interface: infiniteArrayInterface.

Definition cancelCell: val :=
  λ: "cellPtr", let: "cell" := derefCellPointer array_interface "cellPtr" in
                if: getAndSet "cell" CANCELLEDV = RESUMEDV
                then #false
                else cancelCell array_interface "cellPtr" ;; #true.

Definition fromSome: val :=
  λ: "this", match: "this" with
               InjL "v" => "undefined"
             | InjR "v" => "v"
             end.

Definition suspend: val :=
  λ: "enqIterator",
  let: "future" := emptyFuture #() in
  let: "cellPtr" := iteratorStep array_interface "enqIterator" in
  let: "cell" := derefCellPointer array_interface "cellPtr" in
  let: "future'" := SOME ("future", "cellPtr") in
  if: CAS "cell" (InjLV #()) (InjL "future")
  then "future'"
  else let: "value" := !"cell" in
       if: !("value" = BROKENV) && CAS "cell" "value" TAKENV
       then tryCompleteFuture "future" (fromSome "value") ;; "future'"
       else NONEV.

Definition tryCancelThreadQueueFuture: val :=
  λ: "handler" "f", let: "future" := Fst "f" in
                    let: "cellPtr" := Snd "f" in
                    if: tryCancelFuture "future"
                    then "handler" (λ: <>, cancelCell "cellPtr")
                    else #false.

Definition tryResume: val :=
  λ: "maxWait" "shouldAdjust" "mayBreakCells" "deqIterator" "value",
  match: iteratorStepOrIncreaseCounter
           array_interface "shouldAdjust" "deqIterator" with
      NONE => #1
    | SOME "cellPtr" =>
      cellPointerCleanPrev array_interface "cellPtr" ;;
      (rec: "loop" <> :=
         let: "cell" := derefCellPointer array_interface "cellPtr" in
         let: "cellState" := !"cell" in
         if: "cellState" = NONEV then
           if: CAS "cell" NONEV (SOME "value") then
             if: "mayBreakCells" then
               if: (rec: "wait" "n" := ("n" = #0) ||
                                       (!"cell" = TAKENV) ||
                                       "wait" ("n" - #1)) "maxWait" ||
                   !(CAS "cell" (SOME "value") BROKENV)
               then #0
               else #2
             else #0
           else "loop" #()
         else if: "cellState" = CANCELLEDV then #1
         else #() (* TODO *)
      ) #()
  end.

Definition resume: val :=
  rec: "resume" "deqIterator" :=
    let: "cellPtr" :=
       (rec: "loop" <> :=
          match: iteratorStepOrIncreaseCounter
                   array_interface #false "deqIterator" with
            SOME "c" => "c"
          | NONE => "loop" #()
       end) #() in
    cellPointerCleanPrev array_interface "cellPtr" ;;
    let: "cell" := derefCellPointer array_interface "cellPtr" in
    let: "p" := getAndSet "cell" RESUMEDV in
    if: "p" = CANCELLEDV
    then "resume" "deqIterator"
    else match: "p" with
        InjL "x" => "x"
      | InjR "x" => "impossible"
    end.

Definition newThreadQueue: val :=
  λ: <>, let: "arr" := newInfiniteArray array_interface #2 in
         let: "hd" := ref "arr" in
         let: "tl" := ref "arr" in
         let: "enqIdx" := ref #0 in
         let: "deqIdx" := ref #0 in
         (("enqIdx", "hd"), ("deqIdx", "tl")).

End impl.

From iris.base_logic.lib Require Import invariants.
From iris.heap_lang Require Import proofmode.
From iris.algebra Require Import auth numbers list gset excl csum.

Section proof.

(** State **)

Inductive cellRendezvousResolution :=
| cellRendezvousSucceeded
| cellBroken.

Inductive cancellationResult :=
| cellTookValue (v: base_lit)
| cellClosed.

Inductive cancellationResolution :=
| cancellationAllowed (result: option cancellationResult)
| cancellationPrevented.

Inductive futureTerminalState :=
| cellResumed (v: base_lit)
| cellImmediatelyCancelled
| cellCancelled (resolution: option cancellationResolution).

Inductive cellState :=
| cellPassedValue (v: base_lit) (resolution: option cellRendezvousResolution)
| cellInhabited (futureName: gname) (futureLoc: val)
                (resolution: option futureTerminalState).

(** Resource algebras **)

Notation cellInhabitantThreadR := (agreeR (prodO gnameO valO)).

Notation inhabitedCellStateR :=
  (optionR
     (csumR
        (* Future was resumed. *)
        (agreeR valO)
        (* Future was cancelled. *)
        (csumR
           (* Cell was immediately cancelled. *)
           (agreeR unitO)
           (* Cell ony attempts cancellation. *)
           (prodUR
              (* Permits to attempt the later stages of cancellatoin. *)
              natUR
              (optionUR
                 (csumR
                    (* cancellation was logically impossible. *)
                    (agreeR unitO)
                    (* cancellation was allowed. *)
                    (optionUR
                       (csumR
                          (* a value was passed to the cell nonetheless. *)
                          (agreeR valO)
                          (* cancellation completed successfully. *)
                          (agreeR unitO))))))))).

Notation cellStateR :=
  (csumR
     (* Cell was filled with a value. *)
     (prodR
        (agreeR valO)
        (prodUR
           (optionUR (exclR unitO))
           (optionUR
           (* true: value was taken. false: cell is broken. *)
              (agreeR boolO))))
     (* Cell was inhabited. *)
     (prodR
        (* Description of the stored future. *)
        cellInhabitantThreadR
        inhabitedCellStateR)).

Notation queueContentsUR :=
  (prodUR (listUR (optionUR cellStateR))
          (optionUR (exclR natO))).

Notation namesR := (agreeR (prodO (prodO gnameO gnameO) gnameO)).
Notation enqueueUR := natUR.
Notation dequeueUR := (prodUR natUR max_natUR).
Notation algebra := (authUR (prodUR (prodUR (prodUR enqueueUR dequeueUR)
                                            (optionUR namesR))
                                    queueContentsUR)).

Class threadQueueG Σ := ThreadQueueG { thread_queue_inG :> inG Σ algebra }.
Definition threadQueueΣ : gFunctors := #[GFunctor algebra].
Instance subG_threadQueueΣ {Σ} : subG threadQueueΣ Σ -> threadQueueG Σ.
Proof. solve_inG. Qed.

Context `{heapG Σ} `{iteratorG Σ} `{threadQueueG Σ} `{futureG Σ}.
Variable (N NFuture: namespace).
Let NTq := N .@ "tq".
Let NArr := N .@ "array".
Let NDeq := N .@ "deq".
Let NEnq := N .@ "enq".
Notation iProp := (iProp Σ).

Record thread_queue_parameters :=
  ThreadQueueParameters
    {
      is_immediate_cancellation: bool;
      enqueue_resource: iProp;
      dequeue_resource: iProp;
      cell_refusing_resource: iProp;
      passed_value_resource: base_lit -> iProp;
      cell_breaking_resource: iProp;
    }.

Variable parameters: thread_queue_parameters.
Let E := enqueue_resource parameters.
Let R := dequeue_resource parameters.
Let V := passed_value_resource parameters.
Let ERefuse := cell_refusing_resource parameters.
Let CB := cell_breaking_resource parameters.
Let immediateCancellation := is_immediate_cancellation parameters.

Global Instance base_lit_inhabited: Inhabited base_lit.
Proof. repeat econstructor. Qed.

Definition rendezvousResolution_ra r :=
  match r with
  | None => (Excl' (), None)
  | Some cellRendezvousSucceeded => (Excl' (), Some (to_agree true))
  | Some cellBroken => (None, Some (to_agree false))
  end.

Definition cancellationResult_ra r :=
  match r with
  | cellTookValue v => Cinl (to_agree #v)
  | cellClosed => Cinr (to_agree ())
  end.

Definition cancellationResolution_ra r :=
  match r with
  | cancellationAllowed r => Cinr (option_map cancellationResult_ra r)
  | cancellationPrevented => Cinl (to_agree ())
  end.

Definition cancellationResolution_ra' r :=
  match r with
  | None => (2, None)
  | Some d => (1, Some (cancellationResolution_ra d))
  end.

Definition futureTerminalState_ra r :=
  match r with
  | cellResumed v =>
    Cinl (to_agree #v)
  | cellImmediatelyCancelled => Cinr (Cinl (to_agree ()))
  | cellCancelled r => Cinr (Cinr (cancellationResolution_ra' r))
  end.

Definition cellState_ra (state: cellState): cellStateR :=
  match state with
  | cellPassedValue v d => Cinl (to_agree #v,
                                 rendezvousResolution_ra d)
  | cellInhabited γ f r => Cinr (to_agree (γ, f),
                                option_map futureTerminalState_ra r)
  end.

Definition rendezvous_state γtq i (r: option cellStateR) :=
  own γtq (◯ (ε, ({[ i := r ]}, ε))).

Global Instance rendezvous_state_persistent γtq i (r: cellStateR):
  CoreId r -> Persistent (rendezvous_state γtq i (Some r)).
Proof. apply _. Qed.

Definition inhabited_rendezvous_state γtq i (r: inhabitedCellStateR): iProp :=
  ∃ γf f, rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), r))).

Global Instance inhabited_rendezvous_state_persistent γtq i r:
  CoreId r -> Persistent (inhabited_rendezvous_state γtq i r).
Proof. apply _. Qed.

Definition filled_rendezvous_state γtq i r: iProp :=
  ∃ v, rendezvous_state γtq i (Some (Cinl (to_agree v, r))).

Global Instance filled_rendezvous_state_persistent γtq i r:
  CoreId r -> Persistent (filled_rendezvous_state γtq i r).
Proof. apply _. Qed.

Definition cell_breaking_token (γtq: gname) (i: nat): iProp :=
  filled_rendezvous_state γtq i (Excl' (), ε).

Definition cancellation_registration_token (γtq: gname) (i: nat): iProp :=
  inhabited_rendezvous_state γtq i (Some (Cinr (Cinr (2, ε)))).

Definition cell_cancelling_token (γtq: gname) (i: nat): iProp :=
  inhabited_rendezvous_state γtq i (Some (Cinr (Cinr (1, ε)))).

Definition thread_queue_state γ (n: nat) :=
  own γ (◯ (ε, (ε, Excl' n))).

Definition deq_front_at_least γtq (n: nat) :=
  own γtq (◯ (ε, (ε, MaxNat n), ε, ε)).

Definition rendezvous_thread_locs_state (γtq γf: gname) (f: val) (i: nat): iProp :=
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), None))).

Global Instance rendezvous_thread_locs_state_persistent γtq γt th i:
  Persistent (rendezvous_thread_locs_state γtq γt th i).
Proof. apply _. Qed.

Definition rendezvous_filled_value (γtq: gname) (v: base_lit) (i: nat): iProp :=
  rendezvous_state γtq i (Some (Cinl (to_agree #v, ε))).

Definition V' (v: val): iProp := ∃ (x: base_lit), ⌜v = #x⌝ ∧ V x ∗ R.

Definition rendezvous_thread_handle (γtq γt: gname) th (i: nat): iProp :=
  (is_future NFuture V' γt th ∗ rendezvous_thread_locs_state γtq γt th i)%I.

Global Instance rendezvous_thread_handle_persistent γtq γt th i:
  Persistent (rendezvous_thread_handle γtq γt th i).
Proof. apply _. Qed.

Definition rendezvous_initialized γtq i: iProp :=
  inhabited_rendezvous_state γtq i ε ∨ filled_rendezvous_state γtq i ε.

Definition suspension_permit γ := own γ (◯ (1%nat, ε, ε, ε)).

Definition awakening_permit γ := own γ (◯ (ε, (1%nat, ε), ε, ε)).

Variable array_interface: infiniteArrayInterface.
Variable array_spec: infiniteArraySpec _ array_interface.

Let cell_location γtq :=
  infinite_array_mapsto _ _ array_spec NArr (rendezvous_initialized γtq).

Let cancellation_handle := cell_cancellation_handle _ _ array_spec NArr.
Let cell_cancelled := cell_is_cancelled _ _ array_spec NArr.

Definition resources_for_resumer T γf γd i: iProp :=
  ((future_completion_permit γf 1%Qp ∨
    future_completion_permit γf (1/2)%Qp ∗ iterator_issued γd i) ∗ T ∨
   future_completion_permit γf 1%Qp ∗ iterator_issued γd i).

Definition cell_resources
           γtq γa γe γd i (k: option cellState) (insideDeqFront: bool):
  iProp :=
  match k with
  | None => E ∗ if insideDeqFront then R else True%I
  | Some (cellPassedValue v d) =>
    iterator_issued γd i ∗
    cancellation_handle γa i ∗
    ⌜lit_is_unboxed v⌝ ∧
    ∃ ℓ, cell_location γtq γa i ℓ ∗
         match d with
         | None => ℓ ↦ SOMEV #v ∗ E ∗ V v ∗ R
         | Some cellRendezvousSucceeded =>
           ℓ ↦ SOMEV #v ∗ cell_breaking_token γtq i ∗ V v ∗ R ∨
           ℓ ↦ TAKENV ∗ iterator_issued γe i ∗ (E ∨ cell_breaking_token γtq i)
         | Some cellBroken => ℓ ↦ BROKENV ∗ (E ∗ CB ∨ iterator_issued γe i)
         end
  | Some (cellInhabited γf f r) =>
    iterator_issued γe i ∗ rendezvous_thread_handle γtq γf f i ∗
    ∃ ℓ, cell_location γtq γa i ℓ ∗
         match r with
         | None => ℓ ↦ InjLV f ∗ cancellation_handle γa i ∗
                  E ∗ (if insideDeqFront then R else True) ∗
                  future_cancellation_permit γf (1/2)%Qp ∗
                  (future_completion_permit γf 1%Qp ∨
                   future_completion_permit γf (1/2)%Qp ∗
                   iterator_issued γd i)
         | Some (cellResumed v) =>
           (ℓ ↦ InjLV f ∨ ℓ ↦ RESUMEDV) ∗
           iterator_issued γd i ∗
           future_is_completed γf #v ∗
           cancellation_handle γa i ∗
           future_cancellation_permit γf (1/2)%Qp
         | Some cellImmediatelyCancelled =>
           (ℓ ↦ InjLV f ∨ ℓ ↦ CANCELLEDV) ∗
           ⌜immediateCancellation⌝ ∗
           future_is_cancelled γf ∗
           resources_for_resumer (if insideDeqFront then R else True) γf γd i
         | Some (cellCancelled d) =>
           future_is_cancelled γf ∗
           ⌜¬ immediateCancellation⌝ ∗
           match d with
           | None =>
             cancellation_handle γa i ∗
             (if insideDeqFront then R else True) ∗
             (ℓ ↦ InjLV f ∗ E ∗
                (future_completion_permit γf 1%Qp ∨
                 future_completion_permit γf (1/2)%Qp ∗ iterator_issued γd i)
              ∨ ⌜insideDeqFront⌝ ∧
                ∃ v, ⌜lit_is_unboxed v⌝ ∧
                     ℓ ↦ SOMEV #v ∗ iterator_issued γd i ∗
                       future_completion_permit γf 1%Qp ∗ V v)
           | Some cancellationPrevented =>
             ⌜insideDeqFront⌝ ∧
             cancellation_handle γa i ∗
             (ℓ ↦ InjLV f ∗ E ∗
                (future_completion_permit γf 1%Qp ∨
                 future_completion_permit γf (1/2)%Qp ∗ iterator_issued γd i)
              ∨ ℓ ↦ REFUSEDV ∗ resources_for_resumer ERefuse γf γd i
                  ∗ cell_cancelling_token γtq i
              ∨ ∃ v, ⌜lit_is_unboxed v⌝ ∧
                     ℓ ↦ SOMEV #v ∗ iterator_issued γd i ∗
                     future_completion_permit γf 1%Qp ∗ V v)
           | Some (cancellationAllowed d) =>
             match d with
             | None =>
               ℓ ↦ InjLV f ∗ E ∗
               ((future_completion_permit γf 1%Qp ∨
                 future_completion_permit γf (1/2)%Qp ∗ iterator_issued γd i) ∗
                 (if insideDeqFront then awakening_permit γtq else True)
                ∨ future_completion_permit γf 1%Qp ∗ iterator_issued γd i ∗
                  cell_cancelled γa i)
             | Some (cellTookValue v) =>
               (ℓ ↦ SOMEV #v ∗ ⌜lit_is_unboxed v⌝ ∗ V v ∗ awakening_permit γtq ∨
                ℓ ↦ CANCELLEDV ∗ cell_cancelling_token γtq i) ∗
                 iterator_issued γd i ∗
                 future_completion_permit γf 1%Qp
             | Some cellClosed =>
               ℓ ↦ CANCELLEDV ∗
                 cell_cancelling_token γtq i ∗
                 resources_for_resumer
                   (if insideDeqFront then awakening_permit γtq else True) γf γd i
             end
           end
         end
  end.

Definition is_skippable (r: option cellState): bool :=
  match r with
  | Some (cellInhabited
            γt th (Some (cellCancelled (Some (cancellationAllowed _))))) =>
    true
  | _ => false
  end.

Definition is_nonskippable (r: option cellState): bool :=
  negb (is_skippable r).

Definition is_immediately_cancelled (r: option cellState): bool :=
  match r with
  | Some (cellInhabited γt th (Some cellImmediatelyCancelled)) => true
  | _ => false
  end.

Definition cell_list_contents_auth_ra
           (γa γe γd: gname) l (deqFront: nat): algebra :=
  ● (length l, (deqFront, MaxNat deqFront), Some (to_agree (γa, γe, γd)),
     (map (option_map cellState_ra) l,
      Excl' (count_matching is_nonskippable (drop deqFront l)))).

Lemma rendezvous_state_included γ γa γe γd l deqFront i s:
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  rendezvous_state γ i s -∗
  ⌜∃ c, l !! i = Some c ∧ s ≼ option_map cellState_ra c⌝.
Proof.
  iIntros "H● H◯".
  iDestruct (own_valid_2 with "H● H◯")
    as %[[_ [(v&HEl&HInc)%list_singletonM_included _]%prod_included
         ]%prod_included _]%auth_both_valid.
  simpl in *. iPureIntro.
  rewrite map_lookup in HEl.
  destruct (l !! i) as [el|]; simpl in *; simplify_eq.
  eexists. by split.
Qed.

Lemma rendezvous_state_included' γ γa γe γd l deqFront i s:
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  rendezvous_state γ i (Some s) -∗
  ⌜∃ c, l !! i = Some (Some c) ∧ s ≼ cellState_ra c⌝.
Proof.
  iIntros "H● H◯".
  iDestruct (rendezvous_state_included with "H● H◯") as %(c & HEl & HInc).
  iPureIntro.
  destruct c as [el|]; last by apply included_None in HInc.
  simpl in *. eexists. split; first done. move: HInc.
  rewrite Some_included.
  case; last done. intros ->.
  destruct el as [v r|γth f r]; simpl.
  + by apply Cinl_included.
  + by apply Cinr_included.
Qed.

Lemma thread_queue_state_valid γtq γa γe γd n l deqFront:
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  thread_queue_state γtq n -∗
  ⌜n = count_matching is_nonskippable (drop deqFront l)⌝.
Proof.
  iIntros "H● HState".
  iDestruct (own_valid_2 with "H● HState")
    as %[[_ [_ HEq%Excl_included]%prod_included]%prod_included
                                                _]%auth_both_valid.
  by simplify_eq.
Qed.

Theorem cell_list_contents_ra_locs γ γa γe γd l deqFront i γt th:
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  rendezvous_thread_locs_state γ γt th i -∗
  ⌜exists c, l !! i = Some (Some (cellInhabited γt th c))⌝.
Proof.
  iIntros "H● H◯".
  iDestruct (rendezvous_state_included' with "H● H◯") as %([|] & HEl & HInc).
  all: iPureIntro; simpl in *.
  - exfalso. move: HInc. rewrite csum_included. case; first done.
    case.
    * by intros (? & ? & HContra & _).
    * by intros (? & ? & ? & HContra & _).
  - move: HInc. rewrite Cinr_included prod_included=> /=. case.
    rewrite to_agree_included. case=>/=. intros <- <- _.
    by eexists.
Qed.

Definition cell_enqueued γtq (i: nat): iProp :=
  rendezvous_state γtq i ε.

Theorem cell_enqueued_lookup γtq γa γe γd l i d:
  own γtq (cell_list_contents_auth_ra γa γe γd l d) -∗
  cell_enqueued γtq i -∗
  ⌜exists v, l !! i = Some v⌝.
Proof.
  iIntros "H● HExistsEl".
  iDestruct (rendezvous_state_included with "H● HExistsEl") as %(c & HEl & _).
  iPureIntro. eauto.
Qed.

Definition thread_queue_invariant γa γtq γe γd l deqFront: iProp :=
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ∗
      ([∗ list] i ↦ e ∈ l, cell_resources γtq γa γe γd i e
                                          (bool_decide (i < deqFront))) ∗
      ⌜deqFront ≤ length l⌝ ∧
  ⌜deqFront > 0 ∧ (∃ r, l !! (deqFront - 1)%nat = Some r ∧ is_skippable r)
  -> False⌝.

Definition is_thread_queue γa γtq γe γd e d :=
  let co := rendezvous_initialized γtq in
  (inv NTq (∃ l deqFront, thread_queue_invariant γa γtq γe γd l deqFront) ∗
   is_infinite_array _ _ array_spec NArr γa co ∗
   is_iterator _ array_spec NArr NEnq co γa (suspension_permit γtq) γe e ∗
   is_iterator _ array_spec NArr NDeq co γa (awakening_permit γtq) γd d)%I.

Theorem thread_queue_append γtq γa γe γd n l deqFront:
  E -∗ thread_queue_state γtq n -∗
  thread_queue_invariant γa γtq γe γd l deqFront ==∗
  suspension_permit γtq ∗ cell_enqueued γtq (length l) ∗
  thread_queue_state γtq (S n) ∗
  thread_queue_invariant γa γtq γe γd (l ++ [None]) deqFront.
Proof.
  iIntros "HE H◯ (H● & HRRs & HLen & HDeqIdx)".
  iDestruct (thread_queue_state_valid with "H● H◯") as %->.
  iDestruct "HLen" as %HLen.
  iMod (own_update_2 with "H● H◯") as "[H● [[$ $] $]]".
  2: {
    rewrite /thread_queue_invariant app_length big_sepL_app=>/=.
    iFrame "HE H● HRRs".
    iSplitR; first by rewrite bool_decide_false; last lia.
    iDestruct "HDeqIdx" as %HDeqIdx. iPureIntro.
    split; first lia. intros [HContra1 HContra2].
    rewrite lookup_app_l in HContra2; last lia.
    auto.
  }
  {
    apply auth_update, prod_local_update'; last apply prod_local_update'=> /=.
    * rewrite app_length=>/=.
      apply prod_local_update_1, prod_local_update_1=>/=.
      by apply nat_local_update.
    * rewrite map_app=> /=.
      replace (length l) with (length (map (option_map cellState_ra) l))
        by rewrite map_length //.
      rewrite ucmra_unit_right_id.
      apply list_append_local_update=> ?.
      apply list_lookup_validN. by case.
    * etransitivity.
      by apply delete_option_local_update, _.
      rewrite drop_app_le; last lia. rewrite count_matching_app=>/=.
      rewrite Nat.add_1_r.
      by apply alloc_option_local_update.
  }
Qed.

Global Instance deq_front_at_least_persistent γtq n:
  Persistent (deq_front_at_least γtq n).
Proof. apply _. Qed.

Theorem deq_front_at_least_valid γtq γa γe γd n l deqFront :
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  deq_front_at_least γtq n -∗
  ⌜n <= deqFront⌝.
Proof.
  iIntros "H● H◯".
  iDestruct (own_valid_2 with "H● H◯") as %[HValid _]%auth_both_valid.
  apply prod_included in HValid. destruct HValid as [HValid _].
  apply prod_included in HValid. destruct HValid as [HValid _].
  apply prod_included in HValid. destruct HValid as [_ HValid].
  apply prod_included in HValid. destruct HValid as [_ HValid].
  apply max_nat_included in HValid. simpl in *.
  iPureIntro; simpl in *; lia.
Qed.

Theorem cell_list_contents__deq_front_at_least i γtq γa γe γd l deqFront:
  (i <= deqFront)%nat ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ∗
  deq_front_at_least γtq i.
Proof.
  iIntros (HLe) "H●".
  iMod (own_update with "H●") as "[$ $]"; last done.
  apply auth_update_core_id.
  by apply _.
  repeat (apply prod_included; split); simpl.
  all: try apply ucmra_unit_least.
  apply max_nat_included. simpl. lia.
Qed.

Lemma cell_breaking_token_exclusive γtq i:
  cell_breaking_token γtq i -∗ cell_breaking_token γtq i -∗ False.
Proof.
  iIntros "HCb1 HCb2".
  iDestruct "HCb1" as (?) "HCb1". iDestruct "HCb2" as (?) "HCb2".
  iCombine "HCb1" "HCb2" as "HCb". rewrite list_singletonM_op.
  iDestruct (own_valid with "HCb") as %[_ [HValid _]%pair_valid]%pair_valid.
  exfalso. move: HValid=> /=. rewrite list_singletonM_valid.
  case=> _/=. case=>/=. case.
Qed.

Lemma None_op_right_id (A: cmraT) (a: option A): a ⋅ None = a.
Proof. by destruct a. Qed.

Lemma cell_list_contents_cell_update_alloc s
      γtq γa γe γd l deqFront i initialState newState:
  l !! i = Some initialState ->
  is_nonskippable initialState = is_nonskippable newState ->
  (Some (option_map cellState_ra initialState), None) ~l~>
  (Some (option_map cellState_ra newState),
   Some s) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd (<[i := newState]> l) deqFront) ∗
  rendezvous_state γtq i s.
Proof.
  iIntros (HEl HNonSkippable HUp) "H●".
  iMod (own_update with "H●") as "($ & $)"; last done.
  apply auth_update_alloc. rewrite insert_length.
  apply prod_local_update_2, prod_local_update=> /=.
  - rewrite -!fmap_is_map list_fmap_insert.
    apply list_lookup_local_update=> i'. rewrite lookup_nil.
    destruct (lt_eq_lt_dec i' i) as [[HLt| ->]|HGt].
    + rewrite list_lookup_singletonM_lt; last lia.
      rewrite list_lookup_insert_ne; last lia.
      rewrite map_lookup.
      assert (is_Some (l !! i')) as [? ->].
      { apply lookup_lt_is_Some. apply lookup_lt_Some in HEl. lia. }
      apply option_local_update'''. by rewrite ucmra_unit_left_id.
      intros n. by rewrite ucmra_unit_left_id.
    + rewrite list_lookup_singletonM list_lookup_insert.
      2: { eapply lookup_lt_Some. by rewrite map_lookup HEl. }
      by rewrite map_lookup HEl=> /=.
    + rewrite list_lookup_singletonM_gt; last lia.
      rewrite list_lookup_insert_ne; last lia.
      done.
  - rewrite !count_matching_is_sum_map -!fmap_is_map !fmap_drop.
    rewrite list_fmap_insert=> /=. rewrite list_insert_id; first done.
    rewrite map_lookup HEl /= HNonSkippable //.
Qed.

Lemma inhabit_cell_ra γtq γa γe γd l deqFront i γf f:
  l !! i = Some None ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f None)]> l) deqFront) ∗
  rendezvous_thread_locs_state γtq γf f i.
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & $)"; try done.
  apply option_local_update'''.
  by rewrite None_op_right_id.
  intros n. by rewrite None_op_right_id.
Qed.

Lemma rendezvous_state_op γtq i a b:
  rendezvous_state γtq i a ∗ rendezvous_state γtq i b ⊣⊢
  rendezvous_state γtq i (a ⋅ b).
Proof.
  rewrite /rendezvous_state -own_op -auth_frag_op -pair_op.
  rewrite ucmra_unit_left_id -pair_op list_singletonM_op //.
Qed.

Lemma fill_cell_ra γtq γa γe γd l deqFront i v:
  l !! i = Some None ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellPassedValue v None)]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinl (to_agree #v, ε))) ∗
  cell_breaking_token γtq i.
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & H◯)"=>//=.
  { apply option_local_update'''. by rewrite None_op_right_id.
    intros n. by rewrite None_op_right_id. }
  iAssert (rendezvous_state γtq i (Some (Cinl (to_agree #v, ε))))
    with "[H◯]" as "#$".
  { iApply (own_mono with "H◯"). rewrite auth_included; split=> //=.
    do 2 (rewrite prod_included; split=>//=). rewrite list_singletonM_included.
    eexists. rewrite list_lookup_singletonM. split; first done.
    rewrite Some_included Cinl_included prod_included /=. right. split=>//=.
    apply ucmra_unit_least.
  }
  by iExists _.
Qed.

Lemma take_cell_value_ra γtq γa γe γd l deqFront i v:
  l !! i = Some (Some (cellPassedValue v None)) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellPassedValue v (Some cellRendezvousSucceeded))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinl (to_agree #v, (None, Some (to_agree true))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "[$ $]"=> //=.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinl_op -!pair_op None_op_right_id agree_idemp.
Qed.

Lemma cell_list_contents_cell_update newState initialState s s'
      γtq γa γe γd l deqFront i:
  l !! i = Some initialState ->
  is_nonskippable initialState = is_nonskippable newState ∨
  i < deqFront ->
  (option_map cellState_ra initialState, s) ~l~>
  (option_map cellState_ra newState, s') ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  rendezvous_state γtq i s ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd (<[i := newState]> l) deqFront) ∗
  rendezvous_state γtq i s'.
Proof.
  iIntros (HEl HNonSkippable HUp) "H● H◯".
  iMod (own_update_2 with "H● H◯") as "($ & $)"; last done.
  apply auth_update. rewrite insert_length.
  apply prod_local_update_2, prod_local_update=> /=.
  - rewrite -!fmap_is_map list_fmap_insert.
    apply list_lookup_local_update=> i'.
    destruct (lt_eq_lt_dec i' i) as [[HLt| ->]|HGt].
    + rewrite !list_lookup_singletonM_lt; try lia.
      rewrite list_lookup_insert_ne; last lia.
      by rewrite map_lookup.
    + rewrite !list_lookup_singletonM list_lookup_insert.
      2: { eapply lookup_lt_Some. by rewrite map_lookup HEl. }
      rewrite map_lookup HEl=> /=.
      apply option_local_update, HUp.
    + rewrite !list_lookup_singletonM_gt; try lia.
      rewrite list_lookup_insert_ne; last lia.
      done.
  - destruct HNonSkippable as [HNonSkippable|HDeqFront].
    * rewrite !count_matching_is_sum_map -!fmap_is_map !fmap_drop.
      rewrite list_fmap_insert=> /=. rewrite list_insert_id; first done.
      rewrite map_lookup HEl /= HNonSkippable //.
    * by rewrite drop_insert_gt; last lia.
Qed.

Lemma abandon_cell_ra γtq γa γe γd l deqFront i γf f:
  l !! i = Some (Some (cellInhabited γf f (Some (cellCancelled None)))) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  cancellation_registration_token γtq i ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some (cellCancelled (Some cancellationPrevented))))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (1, ε)))))) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (ε, Some (Cinl (to_agree ())))))))).
Proof.
  iIntros (HEl) "H● H◯". iDestruct "H◯" as (? ?) "H◯".
  rewrite rendezvous_state_op.
  iMod (cell_list_contents_cell_update with "H● H◯") as "($ & $)"=>//.
  by left.
  simpl.
  apply option_local_update, csum_local_update_r.
  apply prod_local_update=> /=.
  * apply local_update_total_valid=> _ _. rewrite to_agree_included=> ?.
    simplify_eq. by rewrite agree_idemp.
  * apply option_local_update; do 2 apply csum_local_update_r.
    apply prod_local_update=> /=.
    by apply nat_local_update.
    by apply alloc_option_local_update.
Qed.

Lemma finish_cancellation_ra γtq γa γe γd γf f l deqFront i:
  l !! i = Some (Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed None)))))) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed (Some cellClosed))))))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (ε, Some (Cinr (Some (Cinr (to_agree ())))))))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & $)"=> //=.
  apply option_local_update'''=> [|n].
  by rewrite -Some_op -Cinr_op -!pair_op !agree_idemp.
  rewrite -Some_op -Cinr_op -!pair_op !agree_idemp -Some_op -!Cinr_op.
  by rewrite -pair_op -Some_op -Cinr_op None_op_right_id.
Qed.

Lemma break_cell_ra γtq γa γe γd l deqFront i v:
  l !! i = Some (Some (cellPassedValue v None)) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  cell_breaking_token γtq i ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellPassedValue v (Some cellBroken))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinl (to_agree #v, (None, Some (to_agree false))))).
Proof.
  iIntros (HEl) "H● H◯". iDestruct "H◯" as (?) "H◯".
  iMod (cell_list_contents_cell_update with "H● H◯") as "($ & $)"=>//.
  by left.
  apply option_local_update, csum_local_update_l.
  apply prod_local_update=> /=; last apply prod_local_update=> /=.
  * apply local_update_total_valid=> _ _. rewrite to_agree_included=> ?.
    by simplify_eq.
  * apply delete_option_local_update. apply _.
  * apply alloc_option_local_update. done.
Qed.

Lemma cancel_cell_ra γtq γa γe γd γf f l deqFront i:
  l !! i = Some (Some (cellInhabited γf f None)) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some (cellCancelled None)))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (2, ε)))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & $)"=> //=.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinr_op -!pair_op None_op_right_id !agree_idemp.
Qed.

Lemma immediately_cancel_cell_ra γtq γa γe γd γf f l deqFront i:
  l !! i = Some (Some (cellInhabited γf f None)) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some cellImmediatelyCancelled))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinl (to_agree ())))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & $)"=> //=.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinr_op -!pair_op None_op_right_id !agree_idemp.
Qed.

Lemma resumed_cell_core_id_ra γtq γa γe γd γf f l deqFront i v:
  l !! i = Some (Some (cellInhabited γf f (Some (cellResumed v)))) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f),
                                      Some (Cinl (to_agree #v))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "(H● & $)"=> //=.
  2: by rewrite list_insert_id.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinr_op -!pair_op -Some_op -Cinl_op !agree_idemp.
Qed.

Lemma cancelled_cell_core_id_ra γtq γa γe γd γf f l deqFront i r:
  l !! i = Some (Some (cellInhabited γf f (Some (cellCancelled r)))) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f),
                                      Some (Cinr (Cinr ε))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "(H● & $)"=> //=.
  2: by rewrite list_insert_id.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinr_op -!pair_op -Some_op agree_idemp -!Cinr_op
            ucmra_unit_left_id.
Qed.

Lemma resume_cell_ra γtq γa γe γd γf f l deqFront i v:
  l !! i = Some (Some (cellInhabited γf f None)) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some (cellResumed v)))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinl (to_agree #v))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & $)"=> //=.
  apply option_local_update'''=> [|n];
    by rewrite -Some_op -Cinr_op -!pair_op None_op_right_id !agree_idemp.
Qed.

Lemma awakening_permit_combine γtq n:
  n > 0 ->
  ([∗] replicate n (awakening_permit γtq))%I ≡ own γtq (◯ (ε, (n, ε), ε, ε)).
Proof.
  move=> Hn.
  rewrite big_opL_replicate_irrelevant_element -big_opL_own;
    last by inversion Hn.
  move: (big_opL_op_prodR 0)=> /= HBigOpL.
  rewrite -big_opL_auth_frag !HBigOpL !big_opL_op_ucmra_unit.
  rewrite -big_opL_op_nat' Nat.mul_1_r replicate_length.
  done.
Qed.

Lemma suspension_permit_combine γtq n:
  n > 0 ->
  ([∗] replicate n (suspension_permit γtq))%I ≡ own γtq (◯ (n, ε, ε, ε)).
Proof.
  move=> Hn.
  rewrite big_opL_replicate_irrelevant_element -big_opL_own;
    last by inversion Hn.
  move: (big_opL_op_prodR 0)=> /= HBigOpL.
  rewrite -big_opL_auth_frag !HBigOpL !big_opL_op_ucmra_unit.
  rewrite -big_opL_op_nat' Nat.mul_1_r replicate_length.
  done.
Qed.

Lemma deque_register_ra_update γ γa γe γd l deqFront i n:
  (i + deqFront < length l)%nat ->
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  thread_queue_state γ n ==∗
  own γ (cell_list_contents_auth_ra γa γe γd l (deqFront + S i))
  ∗ [∗] replicate (S i) (awakening_permit γ)
  ∗ thread_queue_state γ
      (n - count_matching is_nonskippable (take (S i) (drop deqFront l)))
  ∗ deq_front_at_least γ (deqFront + S i).
Proof.
  rewrite awakening_permit_combine; last lia.
  iIntros (?) "H● H◯".
  iMod (own_update_2 with "H● H◯") as "($ & $ & $ & $)"; last done.
  apply auth_update, prod_local_update=>/=.
  apply prod_local_update_1, prod_local_update_2, prod_local_update=>/=.
  - rewrite ucmra_unit_right_id. by apply nat_local_update.
  - apply max_nat_local_update; simpl; lia.
  - apply prod_local_update_2. rewrite ucmra_unit_right_id=>/=.
    apply local_update_total_valid=> _ _. rewrite Excl_included=> ->.
    etransitivity. by apply delete_option_local_update, _.
    rewrite count_matching_take.
    assert (∀ n m, m ≤ n -> n - (n - m) = m) as HPure by lia.
    rewrite HPure.
    + rewrite drop_drop. by apply alloc_option_local_update.
    + rewrite count_matching_drop. lia.
Qed.

Lemma allow_cell_cancellation_inside_deqFront_ra
      γ γa γe γd l deqFront i j n γf f:
  let l' := <[j := Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed None)))))]> l in
  find_index is_nonskippable (drop deqFront l') = Some i ->
  j < deqFront ->
  l !! j = Some (Some (cellInhabited γf f (Some (cellCancelled None)))) ->
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  thread_queue_state γ n -∗
  cancellation_registration_token γ j ==∗
  own γ (cell_list_contents_auth_ra γa γe γd l' (deqFront + S i))
  ∗ [∗] replicate (S i) (awakening_permit γ)
  ∗ thread_queue_state γ (n - 1)
  ∗ deq_front_at_least γ (deqFront + S i)
  ∗ rendezvous_state γ j (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (1, ε))))))
  ∗ rendezvous_state γ j (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (ε, Some (Cinr ε))))))).
Proof.
  iIntros (l' HFindSome HDeqFront HEl) "H● H◯1 H◯2".
  iDestruct "H◯2" as (? ?) "H◯2".
  rewrite rendezvous_state_op.
  iMod (cell_list_contents_cell_update with "H● H◯2") as "[H● $]"; try done.
  by right.
  2: {
    iMod (deque_register_ra_update with "H● H◯1") as "($ & $ & H◯ & $)".
    - apply find_index_Some in HFindSome.
      destruct HFindSome as [(v & HEl' & _) _].
      eapply lookup_lt_Some. by rewrite Nat.add_comm -lookup_drop.
    - by move: (present_cells_in_take_Si_if_next_present_is_Si _ _ _ HFindSome)
        => ->.
  }
  simpl.
  apply option_local_update, csum_local_update_r.
  apply prod_local_update=> /=.
  * apply local_update_total_valid=> _ _. rewrite to_agree_included=> ?.
    simplify_eq. by rewrite agree_idemp.
  * apply option_local_update; do 2 apply csum_local_update_r.
    apply prod_local_update=> /=.
    by apply nat_local_update.
    by apply alloc_option_local_update.
Qed.

Lemma allow_cell_cancellation_outside_deqFront_ra
      γ γa γe γd l deqFront j n γf f:
  let l' := <[j := Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed None)))))]> l in
  deqFront ≤ j ->
  l !! j = Some (Some (cellInhabited γf f (Some (cellCancelled None)))) ->
  own γ (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  thread_queue_state γ n -∗
  cancellation_registration_token γ j ==∗
  own γ (cell_list_contents_auth_ra γa γe γd l' deqFront)
  ∗ thread_queue_state γ (n - 1)
  ∗ rendezvous_state γ j (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (1, ε))))))
  ∗ rendezvous_state γ j (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (ε, Some (Cinr ε))))))).
Proof.
  iIntros (l' HDeqFront HEl) "H● H◯1 H◯2".
  iDestruct "H◯2" as (? ?) "H◯2". iCombine "H◯1" "H◯2" as "H◯".
  iMod (own_update_2 with "H● H◯") as "($ & $ & $ & $)"; last done.
  apply auth_update. rewrite insert_length.
  apply prod_local_update_2, prod_local_update=> /=.
  - rewrite -!fmap_is_map list_fmap_insert.
    apply list_lookup_local_update=> i'.
    rewrite list_singletonM_op. simpl.
    destruct (lt_eq_lt_dec i' j) as [[HLt| ->]|HGt].
    + rewrite !list_lookup_singletonM_lt; try lia.
      rewrite list_lookup_insert_ne; last lia.
      by rewrite map_lookup.
    + rewrite !list_lookup_singletonM list_lookup_insert.
      2: { eapply lookup_lt_Some. by rewrite map_lookup HEl. }
      rewrite map_lookup HEl=> /=.
      apply option_local_update, option_local_update, csum_local_update_r.
      apply prod_local_update=>/=.
      * apply local_update_total_valid=> _ _. rewrite to_agree_included=> ?.
        simplify_eq. by rewrite agree_idemp.
      * apply option_local_update; do 2 apply csum_local_update_r.
        apply prod_local_update=> /=.
        by apply nat_local_update.
        by apply alloc_option_local_update.
    + rewrite !list_lookup_singletonM_gt; try lia.
      rewrite list_lookup_insert_ne; last lia.
      done.
  - apply local_update_total_valid=> _ _. rewrite Excl_included=> ?.
    simplify_eq. etransitivity. apply delete_option_local_update. by apply _.
    rewrite drop_insert_le; last lia. rewrite list_insert_alter.
    erewrite count_matching_alter.
    2: { rewrite lookup_drop. replace (_ + _) with j by lia. done. }
    simpl. rewrite Nat.add_0_r.
    by apply alloc_option_local_update.
Qed.

Lemma put_value_in_cancelled_cell_ra v γtq γa γe γd γf f l deqFront i:
  l !! i = Some (Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed None)))))) ->
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra
             γa γe γd (<[i := Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed (Some (cellTookValue v)))))))]> l) deqFront) ∗
  rendezvous_state γtq i (Some (Cinr (to_agree (γf, f), Some (Cinr (Cinr (ε, Some (Cinr (Some (Cinl (to_agree #v)))))))))).
Proof.
  iIntros (HEl) "H●".
  iMod (cell_list_contents_cell_update_alloc with "H●") as "($ & H◯)"=>//=.
  apply option_local_update'''.
  by rewrite -Some_op -Cinr_op -pair_op agree_idemp.
  intros n. rewrite -Some_op -Cinr_op -pair_op agree_idemp -Some_op -Cinr_op.
  by rewrite -Cinr_op -pair_op -Some_op -Cinr_op None_op_right_id.
Qed.

Lemma advance_deqFront i deqFront l γtq γa γe γd:
  find_index is_nonskippable (drop deqFront l) = Some i ->
  [∗] replicate i (awakening_permit γtq) -∗
  ▷ R -∗
  ▷ ([∗ list] k ↦ y ∈ l, cell_resources γtq γa γe γd k y
                                        (bool_decide (k < deqFront))) -∗
  ▷ ([∗ list] k ↦ y ∈ l, cell_resources γtq γa γe γd k y
                                        (bool_decide (k < deqFront + S i))).
Proof.
  iIntros (HFindSome) "HAwaks HR HRRs".
  apply find_index_Some in HFindSome.
  destruct HFindSome as [(v & HEl & HNonSkippable) HRestSkippable].
  rewrite lookup_drop in HEl.
  assert (deqFront + i < length l); first by apply lookup_lt_Some in HEl.
  erewrite <-(take_drop_middle l _ v); last done.
  rewrite !big_sepL_app=>/=.
  iDestruct "HRRs" as "(HInit & H & HTail)".
  apply lookup_lt_Some in HEl. rewrite take_length_le; last lia.
  iSplitL "HInit HAwaks"; last iSplitR "HTail".
  * replace (take _ l) with (take deqFront l ++ take i (drop deqFront l)).
    2: {
      rewrite take_drop_commute.
      replace (take deqFront l) with (take deqFront (take (deqFront + i) l)).
      by rewrite take_drop.
      by rewrite take_take Min.min_l; last lia.
    }
    rewrite !big_sepL_app. iDestruct "HInit" as "[HInit HCancelledCells]".
    iSplitL "HInit".
    { iApply (big_sepL_mono with "HInit"). iIntros (k x HEl') "H".
      assert (k < deqFront)%nat.
      { apply lookup_lt_Some in HEl'.
        by rewrite take_length_le in HEl'; last lia. }
      iEval (rewrite bool_decide_true; last lia).
      rewrite bool_decide_true; last lia. done. }
    { rewrite take_length_le; last lia.
      iAssert (▷ ([∗ list] k ↦ y ∈ take i (drop deqFront l),
              awakening_permit γtq))%I with "[HAwaks]" as "HAwaks".
      { rewrite -big_sepL_replicate.
        rewrite take_length_le //. rewrite drop_length. lia. }
      iCombine "HCancelledCells" "HAwaks" as "HCells".
      rewrite -big_sepL_sep.
      iApply (big_sepL_mono with "HCells"). iIntros (k x HEl') "H".
      assert (k < i)%nat.
      { apply lookup_lt_Some in HEl'. rewrite take_length_le in HEl'=> //.
        rewrite drop_length. lia. }
      rewrite bool_decide_false; last lia.
      rewrite bool_decide_true; last lia.
      rewrite lookup_take in HEl'; last lia.
      specialize (HRestSkippable k).
      destruct HRestSkippable as (y & HEl'' & HSkippable); first lia.
      simplify_eq.
      rewrite /cell_resources.
      rewrite /is_nonskippable in HSkippable.
      destruct x as [[|? ? [[| |[[resolution|]|]]|]]|]=> //.
      iDestruct "H" as "[($ & $ & HRest) HAwak]".
      iDestruct "HRest" as (ℓ) "(H↦ & $ & $ & HRest)".
      iExists ℓ. iFrame "H↦".
      destruct resolution as [[|]|].
      - (* This actually could not have happened: iterator_issued γd could *)
        (* not exist at this point. Thus, we are not "losing" the awakening *)
        (* permit here. *)
        iFrame.
      - iDestruct "HRest" as "($ & $ & [[[H|H] _]|H])";
          [iLeft|iLeft|iRight]; iFrame.
      - iDestruct "HRest" as "($ & $ & [[[H|H] _]|H])";
          [iLeft|iLeft|iRight]; iFrame.
    }
  * rewrite bool_decide_false; last lia.
    rewrite bool_decide_true; last lia.
    rewrite /cell_resources.
    destruct v as [[|? ? [[| |[[|]|]]|]]|]=> //.
    + iDestruct "H" as "($ & $ & H)". iDestruct "H" as (?) "H".
      iExists _. iDestruct "H" as "($ & $ & $ & $ & H)".
      iDestruct "H" as "[[H _]|H]"; [iLeft|iRight]; iFrame; done.
    + iDestruct "H" as "(_ & _ & H)".
      iDestruct "H" as (?) "H".
      iDestruct "H" as "(_ & _ & _ & >HContra & _)".
      iDestruct "HContra" as %[].
    + iDestruct "H" as "($ & $ & H)". iFrame "HR".
      iDestruct "H" as (?) "H". iExists _.
      iDestruct "H" as "($ & $ & $ & $ & _ & [H|H])".
      by iLeft; iFrame.
      by iDestruct "H" as "(>% & _)".
    + iDestruct "H" as "($ & $ & H)". iFrame "HR".
      iDestruct "H" as (?) "H". iExists _.
      by iDestruct "H" as "($ & $ & $ & $ & _ & $)".
    + by iDestruct "H" as "[$ _]".
  * iApply (big_sepL_mono with "HTail"). iIntros (? ? ?) "H".
    rewrite !bool_decide_false; first done; lia.
Qed.

Lemma advance_deqFront_pure i deqFront l:
  find_index is_nonskippable (drop deqFront l) = Some i ->
  deqFront + S i ≤ length l
   ∧ (deqFront + S i > 0
      ∧ (∃ r : option cellState,
           l !! (deqFront + S i - 1) = Some r ∧ is_skippable r) → False).
Proof.
  intros HFindSome.
  apply find_index_Some in HFindSome.
  destruct HFindSome as [(v & HEl & HNonSkippable) HRestSkippable].
  rewrite lookup_drop in HEl.
  assert (deqFront + i < length l); first by apply lookup_lt_Some in HEl.
  split; first lia. case. intros _ (v' & HEl' & HNonSkippable').
  replace (_ - _) with (deqFront + i) in HEl' by lia.
  simplify_eq. rewrite /is_nonskippable in HNonSkippable.
  destruct (is_skippable v); contradiction.
Qed.

Theorem thread_queue_register_for_dequeue γtq γa γe γd l deqFront n:
  ∀ i, find_index is_nonskippable (drop deqFront l) = Some i ->
  ▷ R -∗ ▷ thread_queue_invariant γa γtq γe γd l deqFront -∗
  thread_queue_state γtq n ==∗
  ▷ (awakening_permit γtq
  ∗ deq_front_at_least γtq (deqFront + S i)
  ∗ thread_queue_invariant γa γtq γe γd l (deqFront + S i)
  ∗ thread_queue_state γtq (n - 1)).
Proof.
  iIntros (i HFindSome) "HR (>H● & HRRs & >HLen & >HDeqIdx) H◯".
  iDestruct "HLen" as %HLen.
  move: (present_cells_in_take_Si_if_next_present_is_Si _ _ _ HFindSome)
    => HPresentCells.
  assert (find_index is_nonskippable (drop deqFront l) = Some i) as HFindSome';
    first done.
  apply find_index_Some in HFindSome.
  destruct HFindSome as [(v & HEl & HNonSkippable) HRestSkippable].
  rewrite lookup_drop in HEl.
  assert (deqFront + i < length l); first by apply lookup_lt_Some in HEl.
  iMod (deque_register_ra_update with "H● H◯")
    as "($ & HAwaks & H◯ & $)"; first lia.
  simpl. iDestruct "HAwaks" as "[$ HAwaks]".
  rewrite HPresentCells. iFrame "H◯".
  iDestruct (advance_deqFront with "HAwaks HR HRRs") as "$"; first done.
  iPureIntro. by apply advance_deqFront_pure.
Qed.

Lemma awakening_permit_implies_bound γtq γa γe γd l deqFront n:
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  ([∗] replicate n (awakening_permit γtq)) -∗
  ⌜n <= deqFront⌝.
Proof.
  iIntros "H● HAwaks".
  destruct n; first by iPureIntro; lia.
  rewrite awakening_permit_combine; last lia.
  iDestruct (own_valid_2 with "H● HAwaks")
    as %[[[[_ [HValid%nat_included _]%prod_included]%prod_included
             _]%prod_included _]%prod_included _]%auth_both_valid.
  simpl in *. iPureIntro; lia.
Qed.

Lemma suspension_permit_implies_bound γtq γa γe γd l deqFront n:
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
  ([∗] replicate n (suspension_permit γtq)) -∗
  ⌜n <= length l⌝.
Proof.
  iIntros "H● HSuspends".
  destruct n; first by iPureIntro; lia.
  rewrite suspension_permit_combine; last lia.
  iDestruct (own_valid_2 with "H● HSuspends")
    as %[[[[HValid%nat_included _]%prod_included
             _]%prod_included _]%prod_included _]%auth_both_valid.
  simpl in *. iPureIntro; lia.
Qed.

Global Instance is_thread_queue_persistent γa γ γe γd e d:
  Persistent (is_thread_queue γa γ γe γd e d).
Proof. apply _. Qed.

Lemma cell_cancelled_means_skippable γtq γa γe γd i b c:
  cell_cancelled γa i -∗
  cell_resources γtq γa γe γd i (Some c) b -∗
  ⌜if immediateCancellation
   then is_immediately_cancelled (Some c)
   else is_skippable (Some c)⌝.
Proof.
  iIntros "#HCancelled HRR".
  iAssert (cancellation_handle γa i -∗ False)%I with "[]" as "HContra".
  { iIntros "HCancHandle".
    iDestruct (cell_cancellation_handle_not_cancelled with
                   "HCancelled HCancHandle") as %[]. }
  destruct c as [? c'|? ? c']=> /=.
  { iDestruct "HRR" as "(_ & HCancHandle & _)".
    iDestruct ("HContra" with "HCancHandle") as %[]. }
  iDestruct "HRR" as "(_ & _ & HRR)". iDestruct "HRR" as (ℓ) "[_ HRR]".
  destruct c' as [[| |c']|].
  - iDestruct "HRR" as "(_ & _ & _ & HCancHandle & _)".
    iDestruct ("HContra" with "HCancHandle") as %[].
  - iDestruct "HRR" as "(_ & % & _)". iPureIntro. done.
  - iDestruct "HRR" as "(_ & % & HRR)".
    destruct immediateCancellation; first done.
    destruct c' as [c'|].
    2: { iDestruct "HRR" as "[HCancHandle _]".
         iDestruct ("HContra" with "HCancHandle") as %[]. }
    destruct c'; first done.
    iDestruct "HRR" as "(_ & HCancHandle & _)".
    iDestruct ("HContra" with "HCancHandle") as %[].
  - iDestruct "HRR" as "(_ & HCancHandle & _)".
    iDestruct ("HContra" with "HCancHandle") as %[].
Qed.

Lemma cell_cancelled_means_present E' γtq γa γe γd l deqFront ℓ i:
  ↑NArr ⊆ E' ->
  cell_cancelled γa i -∗
  cell_location γtq γa i ℓ -∗
  ▷ thread_queue_invariant γa γtq γe γd l deqFront ={E'}=∗
  ▷ thread_queue_invariant γa γtq γe γd l deqFront ∗
  ▷ ∃ c, ⌜l !! i = Some (Some c) ∧ if immediateCancellation
                                 then is_immediately_cancelled (Some c)
                                 else is_skippable (Some c)⌝.
Proof.
  iIntros (HSets) "#HCanc #H↦ (>H● & HRRs & >%)".
  iMod (acquire_cell _ _ _ _ _ _ with "H↦")
    as "[[#>HCellInit|[>Hℓ HCancHandle]] HCloseCell]"; first done.
  - iMod ("HCloseCell" with "[HCellInit]") as "_"; first by iLeft. iModIntro.
    iDestruct "HCellInit" as "[HCellInit|HCellInit]".
    1: iDestruct "HCellInit" as (? ?) "HCellInit".
    2: iDestruct "HCellInit" as (?) "HCellInit".
    all: iDestruct (rendezvous_state_included' with "H● HCellInit") as
        %(c & HEl & _).
    all: iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
      first done.
    all: iDestruct (cell_cancelled_means_skippable with "HCanc HRR")
                   as "#HH".
    all: iSpecialize ("HRRsRestore" with "HRR").
    all: iFrame. all: iSplitR; first by iPureIntro. all: iNext.
    all: iDestruct "HH" as "%"; iPureIntro. all: by eexists.
  - iDestruct (cell_cancellation_handle_not_cancelled with "HCanc HCancHandle")
      as ">[]".
Qed.

(* ENTRY POINTS TO THE CELL ****************************************************)

Lemma deq_front_at_least_from_iterator_issued E' γa γtq γe γd e d i:
  ↑N ⊆ E' ->
  is_thread_queue γa γtq γe γd e d -∗
  iterator_issued γd i ={E', E'∖↑NDeq}=∗
  deq_front_at_least γtq (S i) ∗
  iterator_issued γd i ∗
  ▷ |={E'∖↑NDeq, E'}=> True.
Proof.
  iIntros (HMask) "(HInv & _ & _ & HD) HIsRes".
  iMod (access_iterator_resources with "HD [#]") as "HH"; first by solve_ndisj.
  by iDestruct (iterator_issued_is_at_least with "HIsRes") as "$".
  iInv NTq as (l deqFront) "(>H● & HRRs & HRest)" "HClose".
  iDestruct "HH" as "[HH HHRestore]".
  iDestruct (awakening_permit_implies_bound with "H● HH") as "#>%".
  iMod (cell_list_contents__deq_front_at_least with "H●") as "[H● $]"; first lia.
  iFrame "HIsRes".
  iMod ("HClose" with "[-HH HHRestore]") as "_".
  { iExists _, _. iFrame. }
  iSpecialize ("HHRestore" with "HH").
  iModIntro. iApply "HHRestore".
Qed.

Lemma inhabit_cell_spec γa γtq γe γd γf i ptr f e d:
  {{{ is_future NFuture V' γf f ∗
      cell_location γtq γa i ptr ∗
      is_thread_queue γa γtq γe γd e d ∗
      future_completion_permit γf 1%Qp ∗
      future_cancellation_permit γf 1%Qp ∗
      iterator_issued γe i }}}
    CAS #ptr (InjLV #()) (InjLV f)
  {{{ (r: bool), RET #r;
      if r
      then rendezvous_thread_handle γtq γf f i
           ∗ future_cancellation_permit γf (1/2)%Qp
      else filled_rendezvous_state γtq i ε
           ∗ future_completion_permit γf 1%Qp }}}.
Proof.
  iIntros (Φ) "(#HF & #H↦ & #(HInv & HInfArr & HE & _) & HFCompl & HFCanc & HEnq)
               HΦ".
  wp_bind (CmpXchg _ _ _).
  iMod (access_iterator_resources with "HE [#]") as "HH"; first done.
  by iApply (iterator_issued_is_at_least with "HEnq").
  iDestruct "HH" as "[HH HHRestore]".
  iInv "HInv" as (l' deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HTqClose".
  iDestruct (suspension_permit_implies_bound with "H● HH") as "#>HH'".
  iDestruct "HH'" as %HLength. iSpecialize ("HHRestore" with "HH").
  destruct (lookup_lt_is_Some_2 l' i) as [c HEl]; first lia.
  destruct c as [[? resolution|? ? ?]|].
  - (* A value was already passed. *)
    iMod (own_update with "H●") as "[H● HCellFilled]".
    2: iDestruct ("HΦ" $! false with "[HCellFilled HFCompl]") as "HΦ";
      first by iFrame; iExists _.
    { apply auth_update_core_id. by apply _.
      apply prod_included; split=>/=; first by apply ucmra_unit_least.
      apply prod_included; split=>/=; last by apply ucmra_unit_least.
      apply list_singletonM_included. eexists. rewrite map_lookup HEl /=.
      split; first done. apply Some_included. right. apply Cinl_included.
      apply prod_included. split=>/=; first done. apply ucmra_unit_least.
    }
    iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
      first done.
    simpl.
    iDestruct "HRR" as "(H1 & H2 & H3 & HRR)".
    iDestruct "HRR" as (ℓ) "[H↦' HRR]".
    iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
    destruct resolution as [[|]|].
    iDestruct "HRR" as "[HRR|HRR]".
    all: iDestruct "HRR" as "(Hℓ & HRR)"; wp_cmpxchg_fail.
    all: iDestruct ("HRRsRestore" with "[H1 H2 H3 HRR Hℓ]") as "HRRs";
      first by (eauto 10 with iFrame).
    all: iMod ("HTqClose" with "[-HΦ HHRestore]") as "_";
      first by iExists _, _; iFrame.
    all: by iModIntro; iMod "HHRestore"; iModIntro; wp_pures.
  - (* Cell already inhabited? Impossible. *)
    iDestruct (big_sepL_lookup with "HRRs") as "HRR"; first done.
    iDestruct "HRR" as "[>HEnq' _]".
    iDestruct (iterator_issued_exclusive with "HEnq HEnq'") as %[].
  - iMod (acquire_cell _ _ _ _ _ _ with "H↦")
      as "[[#>HCellInit|[>Hℓ HCancHandle]] HCloseCell]";
      first by solve_ndisj.
    { (* We know the rendezvous is not yet initialized. *)
      iAssert (∃ s, rendezvous_state γtq i (Some s))%I with "[]"
        as (?) "HContra".
      { iDestruct "HCellInit" as "[H|H]".
        iDestruct "H" as (? ?) "H"; iExists _; iFrame "H".
        iDestruct "H" as (?) "H"; iExists _; iFrame "H". }
      iDestruct (rendezvous_state_included with "H● HContra")
        as %(c & HEl' & HInc).
      simplify_eq. simpl in HInc. by apply included_None in HInc.
    }
    wp_cmpxchg_suc.
    iMod (inhabit_cell_ra with "H●") as "(H● & #HLoc)"; first done.
    iEval (rewrite -Qp_half_half) in "HFCanc".
    rewrite future_cancellation_permit_Fractional.
    iDestruct "HFCanc" as "[HFHalfCanc1 HFHalfCanc2]".
    iMod ("HCloseCell" with "[]") as "_"; last iModIntro.
    { iLeft. iNext. iLeft. iExists _, _. iApply "HLoc". }
    iSpecialize ("HΦ" $! true with "[$]").
    iMod ("HTqClose" with "[-HΦ HHRestore]").
    2: by iModIntro; iMod "HHRestore"; iModIntro; wp_pures.
    iExists _, _. iFrame "H●". rewrite insert_length. iFrame "HLen".
    iSplitR "HDeqIdx".
    2: {
      iDestruct "HDeqIdx" as %HDeqIdx. iPureIntro.
      case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
      destruct (decide (i = deqFront - 1)).
      - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
        simpl in *. simplify_eq. contradiction.
      - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
    }
    iDestruct (big_sepL_insert_acc with "HRRs") as "[HPre HRRsRestore]";
      first done.
    iApply "HRRsRestore". simpl. iFrame "HEnq HLoc HF".
    iExists _. iFrame "H↦ Hℓ HCancHandle". iDestruct "HPre" as "[$ $]".
    iFrame.
Qed.

Lemma pass_value_to_empty_cell_spec
      (synchronously: bool) γtq γa γe γd i ptr e d v:
  lit_is_unboxed v ->
  {{{ is_thread_queue γa γtq γe γd e d ∗
      deq_front_at_least γtq (S i) ∗
      cell_location γtq γa i ptr ∗
      iterator_issued γd i ∗
      V v }}}
    CAS #ptr (InjLV #()) (InjRV #v)
  {{{ (r: bool), RET #r;
      if r
      then if synchronously
           then cell_breaking_token γtq i ∗ rendezvous_filled_value γtq v i
           else E
      else inhabited_rendezvous_state γtq i ε
  }}}.
Proof.
  iIntros (HValUnboxed Φ) "(#HTq & #HDeqFront & #H↦ & HIsRes & Hv) HΦ".
  wp_bind (CmpXchg _ _ _).
  iDestruct "HTq" as "(HInv & HInfArr & _ & _)".
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HTqClose".
  iDestruct "HLen" as %HLen.
  iDestruct (deq_front_at_least_valid with "H● HDeqFront") as %HDeqFront.
  assert (i < length l) as HLt; first lia.
  apply lookup_lt_is_Some in HLt. destruct HLt as [c HEl].
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRsRestore]"; first done.
  destruct c as [[r|γf f r]|].
  - (* The cell could not have been already filled. *)
    iDestruct "HRR" as "[HIsRes' _]".
    iDestruct (iterator_issued_exclusive with "HIsRes HIsRes'") as ">[]".
  - (* CAS fails, as the suspender already arrived. *)
    iAssert (▷ ∃ v, ⌜v ≠ InjLV #()⌝
                    ∗ ptr ↦ v
                    ∗ (ptr ↦ v -∗ cell_resources γtq γa γe γd i
                           (Some (cellInhabited γf f r))
                           (bool_decide (i < deqFront))))%I
            with "[HRR]" as (inh) "(>% & Hℓ & HRRRestore)".
    {
      simpl. iDestruct "HRR" as "($ & [#HIsFuture $] & HRR)".
      iAssert (▷ ⌜InjLV f ≠ InjLV #()⌝)%I as ">%".
      { iDestruct (future_is_not_unit with "HIsFuture") as ">%".
        iPureIntro. case. intros ->. contradiction. }
      iFrame "HIsFuture".
      iDestruct "HRR" as (ptr') "[H↦' HRR]".
      iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
      destruct r as [[ | |r]|].
      4: iDestruct "HRR" as "[Hℓ $]".
      3: {
        iDestruct "HRR" as "($ & $ & HRR)".
        destruct r as [[[[|]|]|]|];
          try by iDestruct "HRR" as "[Hℓ HRR]";
          iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro);
          iNext; iIntros "Hℓ"; iExists _; by iFrame.
        - iDestruct "HRR" as "(HRR & $ & $)".
          iDestruct "HRR" as "[[Hℓ HRR]|[Hℓ HRR]]".
          all: iExists _; iFrame "Hℓ"; iSplitR; first by iPureIntro.
          all: iNext; iIntros "Hℓ"; iExists _; iFrame "H↦".
          by iLeft; iFrame.
          by iRight; iFrame.
        - iDestruct "HRR" as "($ & $ & HRR)".
          iDestruct "HRR" as "[[Hℓ HRR]|[[Hℓ HRR]|HRR]]".
          + iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro).
            iNext; iIntros "Hℓ"; iExists _. iFrame "H↦". iLeft. iFrame.
          + iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro).
            iNext; iIntros "Hℓ"; iExists _. iFrame "H↦". iRight. iLeft. iFrame.
          + iDestruct "HRR" as (?) "(HUnboxed & Hℓ & HRR)".
            iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro).
            iNext; iIntros "Hℓ"; iExists _. iFrame "H↦". iRight. iRight.
            iExists _. iFrame.
        - iDestruct "HRR" as "($ & HR' & HRR)".
          iDestruct "HRR" as "[[Hℓ HR]|[>% HR]]".
          + iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro).
            iNext; iIntros "Hℓ"; iExists _. iFrame "H↦ HR'". iLeft. iFrame.
          + iDestruct "HR" as (?) "(HUnboxed & Hℓ & HR)".
            iExists _; iFrame "Hℓ"; iSplitR; first (by iPureIntro).
            iNext; iIntros "Hℓ"; iExists _. iFrame "H↦ HR'". iRight.
            iSplitR; first by iPureIntro. iExists _. iFrame.
      }
      2: iDestruct "HRR" as "[[Hℓ|Hℓ] $]".
      1: iDestruct "HRR" as "[[Hℓ|Hℓ] $]".
      all: iExists _; iFrame "Hℓ"; iSplitR; first by iPureIntro.
      all: iNext; iIntros "Hℓ"; iExists _; by iFrame.
    }
    wp_cmpxchg_fail.
    iDestruct ("HRRRestore" with "Hℓ") as "HRR".
    iDestruct ("HRRsRestore" with "HRR") as "HRRs".
    iMod (own_update with "H●") as "[H● H◯]".
    2: iSpecialize ("HΦ" $! false with "[H◯]"); first by iExists _, _.
    {
      apply auth_update_core_id. by apply _.
      apply prod_included=>/=. split; first by apply ucmra_unit_least.
      apply prod_included=>/=. split; last by apply ucmra_unit_least.
      apply list_singletonM_included. eexists.
      rewrite map_lookup HEl=>/=. split; first done.
      rewrite Some_included. right. apply Cinr_included.
      apply prod_included=>/=. split; last by apply ucmra_unit_least.
      done.
    }
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    rewrite list_insert_id; last done.
    iExists _, _. iFrame. iPureIntro; lia.
  - iMod (acquire_cell _ _ _ _ _ _ with "H↦")
      as "[[#>HCellInit|[>Hℓ HCancHandle]] HCloseCell]";
      first by solve_ndisj.
    { (* We know the rendezvous is not yet initialized. *)
      iAssert (∃ s, rendezvous_state γtq i (Some s))%I with "[]"
        as (?) "HContra".
      { iDestruct "HCellInit" as "[H|H]".
        iDestruct "H" as (? ?) "H"; iExists _; iFrame "H".
        iDestruct "H" as (?) "H"; iExists _; iFrame "H". }
      iDestruct (rendezvous_state_included with "H● HContra")
        as %(c & HEl' & HInc).
      simplify_eq. simpl in HInc. by apply included_None in HInc.
    }
    wp_cmpxchg_suc.
    iDestruct "HRR" as "[HE HR]". rewrite bool_decide_true; last lia.
    iMod (fill_cell_ra with "H●") as "(H● & #HInitialized & HCB)"; first done.
    iMod ("HCloseCell" with "[]") as "_"; last iModIntro.
    { iLeft. iRight. iExists _. done. }
    iSpecialize ("HΦ" $! true). destruct synchronously.
    + iSpecialize ("HΦ" with "[HCB]"); first by iFrame.
      iMod ("HTqClose" with "[-HΦ]"); last by iModIntro; wp_pures.
      iExists _, _. iFrame "H●". rewrite insert_length.
      iDestruct "HDeqIdx" as %HDeqIdx. iSplitL.
      2: {
        iPureIntro; split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
        destruct (decide (i = deqFront - 1)).
        - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
          simpl in *. simplify_eq. contradiction.
        - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRsRestore". simpl. iFrame. iSplitR; first done.
      iExists _. by iFrame.
    + iSpecialize ("HΦ" with "HE").
      iMod (take_cell_value_ra with "H●") as "[H● #H◯]".
      { erewrite list_lookup_insert=> //. lia. }
      rewrite list_insert_insert.
      iMod ("HTqClose" with "[-HΦ]"); last by iModIntro; wp_pures.
      iExists _, _. iFrame "H●". rewrite insert_length.
      iDestruct "HDeqIdx" as %HDeqIdx. iSplitL.
      2: {
        iPureIntro; split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
        destruct (decide (i = deqFront - 1)).
        - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
          simpl in *. simplify_eq. contradiction.
        - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRsRestore". simpl. iFrame. iSplitR; first done.
      iExists _. iFrame "H↦".
      iLeft. iFrame.
Qed.

Lemma deq_front_at_least_from_auth_ra γtq γa γe γd l deqFront:
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ==∗
  own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) ∗
  deq_front_at_least γtq deqFront.
Proof.
  iIntros "H●". iMod (own_update with "H●") as "[$ $]"; last done.
  apply auth_update_core_id. by apply _.
  apply prod_included=> /=. split; last by apply ucmra_unit_least.
  apply prod_included=> /=. split; last by apply ucmra_unit_least.
  apply prod_included=> /=. split; first by apply ucmra_unit_least.
  apply prod_included=> /=. split; first by apply ucmra_unit_least.
  done.
Qed.

Theorem dequeue_iterator_update γa γtq γe γd e d:
  ⊢ is_thread_queue γa γtq γe γd e d -∗
    ⌜¬ immediateCancellation⌝ -∗
    make_laterable (∀ l start finish,
      (∀ i, ⌜start ≤ i < finish⌝ -∗ cell_cancelled γa i ∗
                                    (∃ ℓ, cell_location γtq γa i ℓ)) -∗
      ▷ [∗] replicate (S start) (awakening_permit γtq) -∗
      ([∗ list] i ∈ l, ⌜start ≤ i < finish⌝ ∗ iterator_issued γd i)
      ={⊤ ∖ ↑NDeq}=∗ ▷ [∗] replicate ((S start) + length l) (awakening_permit γtq)).
Proof.
  iIntros "(#HInv & _ & _ & _)" (HCanc).
  iApply (make_laterable_intro True%I); last done.
  iModIntro. iIntros "_" (cancelledCells start finish) "#HCancelled".
  iIntros "HPermits HCells".
  rewrite replicate_plus big_sepL_app.
  iInv "HInv" as (l deqFront) "HOpen" "HClose".
  iDestruct "HOpen" as "(>H● & HRRs & HLen & >HDeqFront)".
  iDestruct "HDeqFront" as %HDeqFront.
  iMod (deq_front_at_least_from_auth_ra with "H●") as "[H● #HDeqFront]".
  iDestruct (awakening_permit_implies_bound with "H● HPermits")
    as "#>HDeqFront'".
  iDestruct "HDeqFront'" as %HDeqFront'.
  iFrame "HPermits".
  iAssert (|={⊤ ∖ ↑NDeq ∖ ↑NTq}=>
           ▷ thread_queue_invariant γa γtq γe γd l deqFront ∗
            [∗ list] i ∈ seq start (finish - start - 1),
           ⌜∃ c, l !! i = Some c ∧ is_skippable c⌝)%I
          with "[H● HRRs HLen]" as ">[HTq HSkippable]".
  { remember (finish - start) as r.
    iAssert (▷ thread_queue_invariant γa γtq γe γd l deqFront)%I
      with "[H● HRRs HLen]" as "HTq". by iFrame.
    clear HDeqFront'.
    iInduction r as [|r'] "IH" forall (start Heqr) "HCancelled".
    - simpl. iFrame. by iPureIntro.
    - simpl. destruct r' as [|r''].
      by simpl; iFrame.
      iDestruct ("HCancelled" $! start with "[%]") as "[HCellCancelled H↦]".
      by lia.
      iDestruct "H↦" as (ℓ) "H↦".
      iMod (cell_cancelled_means_present with "HCellCancelled H↦ HTq")
           as "[HH >HH']". by solve_ndisj.
      destruct immediateCancellation. done.
      iDestruct "HH'" as %(c & HEl & HSkippable). simpl.
      iAssert (⌜∃ c, l !! start = Some c ∧ is_skippable c⌝)%I
              with "[%]" as "$"; first by eexists.
      rewrite !Nat.sub_0_r.
      iApply ("IH" $! (S start) with "[%] HH [HCancelled]"). lia.
      iIntros "!>" (i HEl'). iApply "HCancelled". iPureIntro. lia. }
  rewrite big_sepL_forall. iDestruct "HSkippable" as %HSkippable.
  assert (finish ≤ deqFront).
  {
    destruct (decide (finish ≤ deqFront)); first lia. exfalso.
    case HDeqFront. split; first lia.
    eapply (HSkippable (deqFront - start - 1)). apply lookup_seq.
    split; lia.
  }
  iMod ("HClose" with "[HTq]") as "_"; first by iExists _, _; iFrame.
  rewrite big_sepL_replicate big_sepL_later -big_sepL_fupd.
  iApply (big_sepL_impl with "HCells").
  iIntros "!>" (k i _) "[HBounds HIsRes]". iDestruct "HBounds" as %[HB1 HB2].
  iDestruct ("HCancelled" $! i with "[%]") as "[#HCellCanc H↦]"; first lia.
  iDestruct "H↦" as (ℓ) "H↦".
  iInv "HInv" as (l' deqFront') "HOpen" "HClose".
  iMod (cell_cancelled_means_present with "HCellCanc H↦ HOpen")
        as "[HOpen >HFact]".
  by solve_ndisj. iDestruct "HFact" as %(c & HEl & HFact).
  iDestruct "HOpen" as "(>H● & HRRs & HRest)".
  iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  destruct immediateCancellation; first done. simpl in *.
  destruct c as [|? ? [[| |[[c'|]|]]|]]=>//.
  iDestruct "HRR" as "(HIsSus & HTh & HRR)".
  iDestruct "HRR" as (ℓ') "(H↦' & HFutureCancelled & HNotCanc & HRR)".
  iDestruct (deq_front_at_least_valid with "H● HDeqFront") as %HDeqFront''.
  assert (i < deqFront') by lia.
  rewrite bool_decide_true; last lia.
  destruct c' as [[|]|].
  3: iDestruct "HRR" as "(Hℓ & HE & [[[HFC|[_ HC]] >$]|(_ & HC & _)])".
  2: iDestruct "HRR" as "(Hℓ & HTok & [[[HFC|[_ HC]] >$]|[_ HC]])".
  1: iDestruct "HRR" as "(_ & HC & _)".
  all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC") as ">[]".
  all: iMod ("HClose" with "[-]"); last done.
  all: iExists _, _; iFrame; iApply "HRRsRestore".
  all: iFrame. all: iExists _.
  - by iFrame.
  - iFrame. iRight; by iFrame.
Qed.

Lemma read_cell_value_by_resumer_spec γtq γa γe γd i ptr e d:
  {{{ deq_front_at_least γtq (S i) ∗
      is_thread_queue γa γtq γe γd e d ∗
      cell_location γtq γa i ptr ∗
      iterator_issued γd i }}}
    !#ptr
  {{{ (v: val), RET v;
      (⌜v = NONEV⌝ ∧ iterator_issued γd i ∨
       ⌜v = CANCELLEDV⌝ ∧ (if immediateCancellation then R
                           else awakening_permit γtq) ∨
       ⌜v = REFUSEDV⌝ ∧ ERefuse ∨
       ∃ γf f, ⌜v = InjLV f⌝ ∧ rendezvous_thread_handle γtq γf f i ∗
               future_completion_permit γf (1/2)%Qp)
  }}}.
Proof.
  iIntros (Φ) "(#HDeqFront & #(HInv & HInfArr & _ & HD) & #H↦ & HIsRes) HΦ".
  iMod (access_iterator_resources with "HD [#]") as "HH"; first done.
  { iApply (own_mono with "HIsRes"). apply auth_included; split=>//=.
    apply prod_included; split; first by apply ucmra_unit_least.
    apply max_nat_included. simpl. done. }
  iDestruct "HH" as "[HH HHRestore]".
  iMod (acquire_cell _ _ _ _ _ _ with "H↦")
    as "[[#>HCellInit|[>Hℓ HCancHandle]] HCloseCell]"; first by solve_ndisj.
  2: { (* Cell was not yet inhabited, so NONEV is written in it. *)
    wp_load. iMod ("HCloseCell" with "[Hℓ HCancHandle]") as "_".
    by iRight; iFrame. iModIntro. iMod ("HHRestore" with "HH").
    iApply "HΦ". by iLeft; iFrame.
  }
  iSpecialize ("HCloseCell" with "[HCellInit]"); first by iLeft.
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HTqClose".
  iDestruct (awakening_permit_implies_bound with "H● HH") as "#>HValid".
  iDestruct "HValid" as %HValid.
  iSpecialize ("HHRestore" with "[HH]"); first done.
  iDestruct "HCellInit" as "[HCellInhabited|HCellFilled]".
  2: { (* Cell could not have been filled already, we hold the permit. *)
    iDestruct "HCellFilled" as (?) "HCellFilled".
    iDestruct (rendezvous_state_included' with "H● HCellFilled")
      as %(c & HEl & HInc).
    destruct c as [? c'|].
    2: { exfalso. simpl in *. move: HInc. rewrite csum_included.
        case; first done. case; by intros (? & ? & ? & ? & ?). }
    iDestruct (big_sepL_lookup with "HRRs") as "HRR"; first done.
    iDestruct "HRR" as "[>HContra _]".
    iDestruct (iterator_issued_exclusive with "HContra HIsRes") as %[].
  }
  (* Cell was inhabited. *)
  iDestruct "HCellInhabited" as (? ?) "HCellInhabited".
  iDestruct (rendezvous_state_included' with "H● HCellInhabited")
    as %(c & HEl & HInc).
  destruct c as [? c'|? ? c'].
  1: { exfalso. simpl in *. move: HInc. rewrite csum_included.
        case; first done. case; by intros (? & ? & ? & ? & ?). }
  move: HInc; rewrite Cinr_included pair_included to_agree_included.
  case. case=> /= HEq1 HEq2 _. simplify_eq.
  iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  iDestruct (deq_front_at_least_valid with "H● HDeqFront") as %HDeqFront.
  rewrite bool_decide_true; last lia.
  iDestruct "HRR" as "(HIsSus & #HTh & HRR)". iDestruct "HRR" as (ℓ) "[H↦' HRR]".
  iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
  destruct c' as [[| |c'']|].
  - (* Cell could not have been resumed already. *)
    iDestruct "HRR" as "(_ & >HContra & _)".
    iDestruct (iterator_issued_exclusive with "HContra HIsRes") as %[].
  - iDestruct "HRR" as
        "(Hℓ & >HImmediate & HCancelled & [HCompletion|[_ HC]])".
    iDestruct "HImmediate" as %HImmediate.
    iDestruct "HCompletion" as "[[HCompletionPermit|[_ HC]] HR]".
    all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC") as ">[]".
    iDestruct "Hℓ" as "[Hℓ|Hℓ]"; wp_load.
    + iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HCompletionPermit".
      iDestruct "HCompletionPermit" as "[HCompl1 HCompl2]".
      iSpecialize ("HΦ" $! (InjLV _) with "[HCompl2]").
      { repeat iRight. iExists _, _. iFrame. iSplit; last by iAssumption. done. }
      iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
      2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
      iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
      iFrame "HIsSus HTh HCancelled". iExists _. iFrame "H↦".
      iSplitL "Hℓ"; first by iLeft. iSplitR; first done. iLeft. iFrame.
      iRight; iFrame.
    + iSpecialize ("HΦ" $! CANCELLEDV with "[HR]").
      { iRight. iLeft. destruct immediateCancellation=> //. by iFrame. }
      iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
      2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
      iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
      iFrame "HIsSus HTh HCancelled". iExists _. iFrame "H↦".
      iSplitL "Hℓ"; first by iRight. iSplitR; first done. iRight. iFrame.
  - iDestruct "HRR" as "(HCancelled & >HNotImmediate & HRR)".
    iDestruct "HNotImmediate" as %HNotImmediate.
    destruct c'' as [[[[|]|]|]|].
    + (* Value couldn't have been taken, as it hasn't been passed. *)
      iDestruct "HRR" as "(_ & HC & _)".
      by iDestruct (iterator_issued_exclusive with "HIsRes HC") as ">[]".
    + (* The cell was cancelled successfully. *)
      iDestruct "HRR" as "(Hℓ & HTok & [[[HFutureCompl|[_ HC]] HAwak]|[_ HC]])".
      all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC")
          as ">[]".
      wp_load.
      iSpecialize ("HΦ" $! CANCELLEDV with "[HAwak]").
      { iRight. iLeft. iSplitR; first done. by destruct immediateCancellation. }
      iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
      2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
      iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
      iFrame "HIsSus HTh HCancelled". iExists _. iFrame "H↦ Hℓ HTok".
      iSplitR; first done. iRight. iFrame.
    + (* The cell is attempting to cancel. *)
      iDestruct "HRR" as "(Hℓ & HE & [[[HFutureCompl|[_ HC]] HAwak]|(_&HC&_)])".
      all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC")
          as ">[]".
      iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HFutureCompl".
      iDestruct "HFutureCompl" as "[HCompl1 HCompl2]".
      wp_load.
      iSpecialize ("HΦ" $! (InjLV _) with "[HCompl2]").
      { repeat iRight. iExists _, _. iFrame. iSplit=>//. }
      iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
      2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
      iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
      iFrame "HIsSus HTh HCancelled". iExists _. iFrame "H↦ Hℓ HE".
      iSplitR; first done. iLeft. iFrame. iRight; iFrame.
    + (* Cancellation was prevented. *)
      iDestruct "HRR" as "(HInside & HCancHandle & HRR)".
      iDestruct "HRR" as "[(Hℓ & HE & [HFutureCompl|[_ HC]])|
        [(Hℓ & [[[HFutureCompl|[_ HC]] HE]|[_ HC]] & HCancTok)|HRR]]";
        last iDestruct "HRR" as (?) "(_ & _ & HC & _)".
      all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC")
          as ">[]".
      all: wp_load.
      { iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
          in "HFutureCompl".
        iDestruct "HFutureCompl" as "[HCompl1 HCompl2]".
        iSpecialize ("HΦ" $! (InjLV _) with "[HCompl2]").
        { repeat iRight. iExists _, _. iFrame. iSplit=>//. }
        iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
        2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
        iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
        iFrame "HInside HIsSus HTh HCancelled HCancHandle". iExists _.
        iFrame "H↦". iSplitR; first done. iLeft. iFrame. iRight. iFrame. }
      { iSpecialize ("HΦ" $! REFUSEDV with "[HE]").
        { iRight. iRight. iLeft. by iFrame. }
        iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
        2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
        iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
        iFrame "HInside HIsSus HTh HCancelled HCancHandle". iExists _.
        iFrame "H↦". iSplitR; first done. iRight. iLeft. iFrame. }
    + (* Cell was cancelled, but this fact was not registered. *)
      iDestruct "HRR" as "(HCancHandle & HR' &
        [(Hℓ & HE & [HFutureCompl|[_ HC]])|(_ & HRR)])";
        last iDestruct "HRR" as (?) "(_ & _ & HC & _)".
      all: try by iDestruct (iterator_issued_exclusive with "HIsRes HC")
          as ">[]".
      iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HFutureCompl".
      iDestruct "HFutureCompl" as "[HCompl1 HCompl2]".
      wp_load.
      iSpecialize ("HΦ" $! (InjLV _) with "[HCompl2]").
      { repeat iRight. iExists _, _. iFrame. iSplit=>//. }
      iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
      2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
      iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
      iFrame "HCancHandle HIsSus HTh". iExists _. iFrame "H↦ HCancelled".
      iSplitR; first done. iFrame "HR'". iLeft. iFrame. iRight. iFrame.
  - iDestruct "HRR" as "(Hℓ & HCancHandle & HE & HR & HFutureCanc &
      [HFutureCompl|[_ HC]])".
    2: by iDestruct (iterator_issued_exclusive with "HIsRes HC") as ">[]".
    iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
      in "HFutureCompl".
    iDestruct "HFutureCompl" as "[HCompl1 HCompl2]".
    wp_load.
    iSpecialize ("HΦ" $! (InjLV _) with "[HCompl2]").
    { repeat iRight. iExists _, _. iFrame. iSplit=>//. }
    iMod ("HTqClose" with "[-HCloseCell HHRestore HΦ]").
    2: iModIntro; iMod "HCloseCell"; iModIntro; by iMod "HHRestore".
    iExists _, _. iFrame "H● HDeqIdx HLen". iApply "HRRsRestore".
    iFrame "HCancHandle HIsSus HTh". iExists _. iFrame "H↦". iFrame.
    iRight. iFrame.
Qed.

(* TRANSITIONS ON CELLS IN THE NON-SUSPENDING CASE *****************************)

Lemma check_passed_value (possibly_async: bool) γtq γa γe γd i (ptr: loc) vf:
  rendezvous_filled_value γtq vf i -∗
  cell_location γtq γa i ptr -∗
  (if possibly_async then True else cell_breaking_token γtq i) -∗
  <<< ∀ l deqFront, ▷ thread_queue_invariant γa γtq γe γd l deqFront >>>
    !#ptr @ ⊤
  <<< ∃ v, thread_queue_invariant γa γtq γe γd l deqFront ∗
           (if possibly_async then True else cell_breaking_token γtq i) ∗
           ⌜match l !! i with
           | Some (Some (cellPassedValue _ d)) =>
             match d with
               | None => v = InjRV #vf
               | Some cellBroken => v = BROKENV
               | Some cellRendezvousSucceeded =>
                 v = TAKENV ∨ possibly_async ∧ v = InjRV #vf
             end
           | _ => False
           end⌝, RET v >>>.
Proof.
  iIntros "#HFilled #H↦ HCellBreaking" (Φ) "AU".
  iMod "AU" as (l deqFront) "[(>H● & HRRs & >HLen & >HDeqIdx) [_ HClose]]".
  iDestruct (rendezvous_state_included' with "H● HFilled") as %(c & HEl & HInc).
  rewrite HEl. destruct c as [? c'|].
  2: { exfalso. simpl in *. move: HInc. rewrite csum_included.
       case; first done. case; by intros (? & ? & ? & ? & ?). }
  move: HInc. rewrite Cinl_included pair_included to_agree_included. case=> HEq _.
  simplify_eq.
  iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  simpl. iDestruct "HRR" as "(HIsRes & HCancHandle & HValUnboxed & HRR)".
  iDestruct "HRR" as (ℓ) "[H↦' HRR]".
  iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
  destruct c' as [[|]|]=> /=.
  - iDestruct "HRR" as "[(Hptr & HCellBreaking' & HRR)|(Hptr & HRR)]"; wp_load.
    all: iMod ("HClose" with "[-]") as "HΦ"; last by iModIntro.
    * destruct possibly_async.
      + iSplitL; last iPureIntro.
        { iFrame "H● HLen HDeqIdx". iApply "HRRsRestore".
          iFrame "HIsRes HCancHandle HValUnboxed".
          iExists _. iFrame "H↦". iLeft. iFrame. }
        by split; [|right].
      + iDestruct (cell_breaking_token_exclusive
                     with "HCellBreaking HCellBreaking'") as %[].
    * iFrame "HCellBreaking". iSplitL; last by iPureIntro; left.
      iFrame "H● HLen HDeqIdx". iApply "HRRsRestore".
      iFrame "HIsRes HCancHandle HValUnboxed".
      iExists _. iFrame "H↦". iRight. iFrame.
  - iDestruct "HRR" as "[Hptr HRR]". wp_load.
    iMod ("HClose" with "[-]") as "HΦ"; last by iModIntro.
    iFrame "HCellBreaking". iSplitL; last by iPureIntro.
    iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". iFrame. iExists _. by iFrame.
  - iDestruct "HRR" as "[Hptr HRR]". wp_load.
    iMod ("HClose" with "[-]") as "HΦ"; last by iModIntro.
    iFrame "HCellBreaking". iSplitL; last by iPureIntro; eexists.
    iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". iFrame. iExists _. by iFrame.
Qed.

Lemma break_cell_spec γtq γa γe γd i ptr e d v:
  {{{ is_thread_queue γa γtq γe γd e d ∗
      cell_location γtq γa i ptr ∗
      rendezvous_filled_value γtq v i ∗
      cell_breaking_token γtq i ∗ CB }}}
    CAS #ptr (InjRV #v) BROKENV
  {{{ (r: bool), RET #r; if r then V v ∗ R else E }}}.
Proof.
  iIntros (Φ) "(#HTq & #H↦ & #HFilled & HCellBreaking & HCB) HΦ".
  iDestruct "HTq" as "(HInv & HInfArr & _ & _)". wp_bind (CmpXchg _ _ _).
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HTqClose".
  iDestruct "HLen" as %HLen.
  iDestruct (rendezvous_state_included' with "H● HFilled") as %(c & HEl & HInc).
  destruct c as [? c'|].
  2: { exfalso. simpl in *. move: HInc. rewrite csum_included.
       case; first done. case; by intros (? & ? & ? & ? & ?). }
  move: HInc. rewrite Cinl_included pair_included to_agree_included. case=> HEq _.
  simplify_eq.
  destruct c' as [[|]|]=> /=.
  - (* Rendezvous succeeded, breaking the cell is impossible, so we take E. *)
    iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
      first done.
    simpl. iDestruct "HRR" as "(HIsRes & HCancHandle & >% & HRR)".
    iDestruct "HRR" as (ℓ) "[H↦' HRR]".
    iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
    iDestruct "HRR" as "[(_ & HContra & _)|(Hℓ & HIsSus & [HE|HContra])]".
    all: try by iDestruct (cell_breaking_token_exclusive
                             with "HCellBreaking HContra") as ">[]".
    wp_cmpxchg_fail. iSpecialize ("HΦ" $! false with "HE").
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    iExists _, _. iFrame "H● HDeqIdx". iSplitL; last by iPureIntro.
    iApply "HRRsRestore". iFrame "HIsRes HCancHandle". iSplitR; first done.
    iExists _. iFrame "H↦". iRight. iFrame.
  - (* Cell was broken before we arrived? Impossible. *)
    iDestruct "HCellBreaking" as (?) "HCellBreaking".
    iDestruct (rendezvous_state_included' with "H● HCellBreaking")
      as %(? & HEl' & HInc).
    exfalso. move: HInc. simplify_eq=>/=. rewrite Cinl_included pair_included.
    case=> _. rewrite pair_included; case=> HContra.
    by apply included_None in HContra.
  - (* Cell is still intact, so we may break it. *)
    iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRsRestore]";
      first done.
    simpl. iDestruct "HRR" as "(HIsRes & HCancHandle & >% & HRR)".
    iDestruct "HRR" as (ℓ) "(H↦' & Hℓ & HE & HV & HR)".
    iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
    wp_cmpxchg_suc. iSpecialize ("HΦ" $! true with "[$]").
    iMod (break_cell_ra with "H● HCellBreaking") as "[H● #H◯]"; first done.
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    iDestruct "HDeqIdx" as %HDeqIdx.
    iExists _, _. iFrame "H●". rewrite insert_length. iSplitL.
    2: {
      iPureIntro; split; first lia.
      case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
      destruct (decide (i = deqFront - 1)).
      - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
        simpl in *. simplify_eq. contradiction.
      - rewrite list_lookup_insert_ne in HEl'; last lia.
      eexists. done.
    }
    iApply "HRRsRestore". simpl. iFrame "HIsRes HCancHandle".
    iSplitR; first done. iExists _. iFrame "H↦". iFrame "Hℓ". iLeft. iFrame.
Qed.

Lemma take_cell_value_spec γtq γa γe γd i ptr e d v:
  {{{ is_thread_queue γa γtq γe γd e d ∗
      cell_location γtq γa i ptr ∗
      rendezvous_filled_value γtq v i ∗
      iterator_issued γe i }}}
    CAS #ptr (InjRV #v) TAKENV
  {{{ (r: bool), RET #r; if r then V v ∗ R else CB ∗ E }}}.
Proof.
  iIntros (Φ) "(#HTq & #H↦ & #HFilled & HIsSus) HΦ".
  iDestruct "HTq" as "(HInv & HInfArr & _ & _)". wp_bind (CmpXchg _ _ _).
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HTqClose".
  iDestruct "HLen" as %HLen.
  iDestruct (rendezvous_state_included' with "H● HFilled") as %(c & HEl & HInc).
  destruct c as [? c'|].
  2: { exfalso. simpl in *. move: HInc. rewrite csum_included.
       case; first done. case; by intros (? & ? & ? & ? & ?). }
  move: HInc. rewrite Cinl_included pair_included to_agree_included. case=> HEq _.
  simplify_eq.
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  simpl. iDestruct "HRR" as "(HIsRes & HCancHandle & >% & HRR)".
  iDestruct "HRR" as (ℓ) "[H↦' HRR]".
  iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
  destruct c' as [[|]|]=> /=.
  - (* Rendezvous succeeded even before we arrived. *)
    iSpecialize ("HRRsRestore" $! _); rewrite list_insert_id //.
    iDestruct "HRR" as "[(Hℓ & HCellBreaking & HV & HR)|(_ & HContra & _)]".
    2: by iDestruct (iterator_issued_exclusive with "HIsSus HContra") as ">[]".
    wp_cmpxchg_suc. iSpecialize ("HΦ" $! true with "[$]").
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    iExists _, _. iFrame "H● HDeqIdx". iSplitL; last by iPureIntro.
    iApply "HRRsRestore". iFrame "HIsRes HCancHandle". iSplitR; first done.
    iExists _. iFrame "H↦". iRight. iFrame.
  - (* Cell was broken before we arrived. *)
    iSpecialize ("HRRsRestore" $! _); rewrite list_insert_id //.
    iDestruct "HRR" as "(Hℓ & [[HE HCB]|HContra])".
    2: by iDestruct (iterator_issued_exclusive with "HIsSus HContra") as ">[]".
    wp_cmpxchg_fail. iSpecialize ("HΦ" $! false with "[$]").
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    iExists _, _. iFrame "H● HDeqIdx". iSplitL; last by iPureIntro.
    iApply "HRRsRestore". iFrame "HIsRes HCancHandle". iSplitR; first done.
    iExists _. iFrame "H↦". iFrame.
  - (* Cell is still intact, so we may take the value from it. *)
    iDestruct "HRR" as "(Hℓ & HE & HV & HR)".
    wp_cmpxchg_suc. iSpecialize ("HΦ" $! true with "[$]").
    iMod (take_cell_value_ra with "H●") as "[H● #H◯]"; first done.
    iMod ("HTqClose" with "[-HΦ]") as "_"; last by iModIntro; wp_pures.
    iDestruct "HDeqIdx" as %HDeqIdx.
    iExists _, _. iFrame "H●". rewrite insert_length. iSplitL.
    2: {
      iPureIntro; split; first lia.
      case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
      destruct (decide (i = deqFront - 1)).
      - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
        simpl in *. simplify_eq. contradiction.
      - rewrite list_lookup_insert_ne in HEl'; last lia.
      eexists. done.
    }
    iApply "HRRsRestore". simpl. iFrame "HIsRes HCancHandle".
    iSplitR; first done. iExists _. iFrame "H↦". iRight. iFrame.
Qed.

(* DEALING WITH THE SUSPENDED FUTURE *******************************************)

Lemma try_cancel_cell γa γtq γe γd e d γf f i:
  NTq ## NFuture ->
  is_thread_queue γa γtq γe γd e d -∗
  rendezvous_thread_handle γtq γf f i -∗
  <<< future_cancellation_permit γf (1/2)%Qp >>>
    tryCancelFuture f @ ⊤ ∖ ↑NFuture ∖ ↑NTq
  <<< ∃ (r: bool),
      if r then future_is_cancelled γf ∗
        if immediateCancellation
        then inhabited_rendezvous_state γtq i (Some (Cinr (Cinl (to_agree ()))))
        else cancellation_registration_token γtq i
      else
        (∃ v, inhabited_rendezvous_state γtq i (Some (Cinl (to_agree #v))) ∗
              ▷ future_is_completed γf #v) ∗
        future_cancellation_permit γf (1/2)%Qp,
      RET #r >>>.
Proof.
  iIntros (HMask) "[#HInv _] #[HFuture H◯]". iIntros (Φ) "AU".
  awp_apply (tryCancelFuture_spec with "HFuture").
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct (rendezvous_state_included' with "H● H◯")
    as %(c & HEl & HInc).
  destruct c as [? ?|? ? r].
  { exfalso. simpl in *. move: HInc. rewrite csum_included.
    case; first done. case; by intros (? & ? & ? & ? & ?). }
  simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
  rewrite to_agree_included. case=> /= ? ? _. simplify_eq.
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  simpl.
  iDestruct "HRR" as "(HIsSus & HTh' & HRR)". iDestruct "HRR" as (ℓ) "[#H↦ HRR]".
  iApply (aacc_aupd_commit with "AU"). by solve_ndisj. iIntros "HCancPermit".
  destruct r as [[| |]|].
  (* Could not have been cancelled: we hold the permit. *)
  2: iDestruct "HRR" as "(_ & _ & HContra & _)".
  3: iDestruct "HRR" as "[HContra _]".
  all: try by iDestruct (future_cancellation_permit_implies_not_cancelled
                           with "HCancPermit HContra") as ">[]".
  - (* Cell was already resumed. *)
    iDestruct "HRR" as "(Hℓ & HIsRes & #HCompleted & HCancHandle & >HPermit)".
    iCombine "HCancPermit" "HPermit" as "HPermit'".
    rewrite -future_cancellation_permit_Fractional Qp_half_half.
    iAaccIntro with "HPermit'".
    { iIntros "HCancPermit !>".
      iEval (rewrite -Qp_half_half future_cancellation_permit_Fractional)
        in "HCancPermit".
      iDestruct "HCancPermit" as "[$ HPermit]". iIntros "$ !>".
      iExists _, _. iSpecialize ("HRRsRestore" $! _).
      rewrite list_insert_id //.
      iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame. }
    iIntros (r) "Hr". destruct r.
    by iDestruct (future_is_completed_not_cancelled
                    with "HCompleted [$]") as ">[]".
    iDestruct "Hr" as "[_ HCancPermit]".
    iEval (rewrite -Qp_half_half future_cancellation_permit_Fractional)
      in "HCancPermit".
    iDestruct "HCancPermit" as "[HCancPermit HPermit]".
    iMod (resumed_cell_core_id_ra with "H●") as "[H● H◯']"; first done.
    iModIntro. iExists false. iFrame "HPermit". iSplitL "H◯'".
    { iExists _. iFrame "HCompleted". iExists _, _. iFrame "H◯'". }
    iIntros "$ !>".
    iExists _, _. iSpecialize ("HRRsRestore" $! _).
    rewrite list_insert_id //.
    iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
    iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame.
  - (* Cell was neither resumed nor cancelled. *)
    iDestruct "HRR" as "(Hℓ & HCancHandle & HE & HR & >HPermit & HRR)".
    iCombine "HCancPermit" "HPermit" as "HPermit'".
    rewrite -future_cancellation_permit_Fractional Qp_half_half.
    iAaccIntro with "HPermit'".
    { iIntros "HCancPermit !>".
      iEval (rewrite -Qp_half_half future_cancellation_permit_Fractional)
        in "HCancPermit".
      iDestruct "HCancPermit" as "[$ HPermit]". iIntros "$ !>".
      iExists _, _. iSpecialize ("HRRsRestore" $! _).
      rewrite list_insert_id //.
      iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame. }
    iIntros (r) "Hr". destruct r.
    2: {
      iDestruct "Hr" as "[Hr _]". iDestruct "Hr" as (?) "HFutureCompleted".
      iDestruct "HRR" as "[>HContra|[>HContra _]]".
      all: iDestruct (future_completion_permit_implies_not_completed
                        with "HContra HFutureCompleted") as %[].
    }
    iExists true. iDestruct "Hr" as "#HCancelled". iFrame "HCancelled".
    remember immediateCancellation as hi eqn: HCancellation. destruct hi.
    + iMod (immediately_cancel_cell_ra with "H●") as "[H● H◯']"; first done.
      iSplitL "H◯'". by iExists _, _.
      iIntros "!> $ !>".
      iDestruct "HLen" as %HLen. iDestruct "HDeqIdx" as %HDeqIdx.
      iExists _, _. iFrame "H●". rewrite insert_length. iSplitL.
      2: {
        iPureIntro. split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
        destruct (decide (i = deqFront - 1)).
        - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
          simpl in *. simplify_eq. contradiction.
        - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRsRestore". iFrame. iExists _. iFrame "H↦ HCancelled".
      iSplitL "Hℓ"; first by iFrame. rewrite -HCancellation.
      iSplitR; first done. rewrite /resources_for_resumer.
      iLeft. iFrame.
    + iMod (cancel_cell_ra with "H●") as "[H● H◯']"; first done.
      iSplitL "H◯'". by iExists _, _.
      iIntros "!> $ !>".
      iDestruct "HLen" as %HLen. iDestruct "HDeqIdx" as %HDeqIdx.
      iExists _, _. iFrame "H●". rewrite insert_length. iSplitL.
      2: {
        iPureIntro. split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
        destruct (decide (i = deqFront - 1)).
        - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
          simpl in *. simplify_eq. contradiction.
        - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRsRestore". iFrame. iExists _. iFrame "H↦ HCancelled".
      rewrite -HCancellation. iSplitR; first by iPureIntro; case.
      iLeft. iFrame.
Qed.

Lemma try_resume_cell γa γtq γe γd e d γf f i v:
  NTq ## NFuture ->
  Laterable (V v) ->
  deq_front_at_least γtq (S i) -∗
  is_thread_queue γa γtq γe γd e d -∗
  rendezvous_thread_handle γtq γf f i -∗
  ▷ V v -∗
  <<< future_completion_permit γf (1/2)%Qp >>>
    tryCompleteFuture f #v @ ⊤ ∖ ↑NFuture ∖ ↑NTq
  <<< ∃ (r: bool),
      if r then ▷ E ∗ future_is_completed γf #v ∗
                inhabited_rendezvous_state γtq i (Some (Cinl (to_agree #v)))
      else ▷ V v ∗
           if immediateCancellation
           then ▷ R
           else inhabited_rendezvous_state γtq i (Some (Cinr (Cinr ε))) ∗
                iterator_issued γd i,
      RET #r >>>.
Proof.
  iIntros (HMask HLat) "#HDeqFront [#HInv _] #[HFuture H◯] HV". iIntros (Φ) "AU".
  awp_apply (tryCompleteFuture_spec _ true with "HFuture"). rewrite /V'.
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct (deq_front_at_least_valid with "H● HDeqFront") as %HFront.
  iDestruct (rendezvous_state_included' with "H● H◯")
    as %(c & HEl & HInc).
  destruct c as [? ?|γf' f' r].
  { exfalso. simpl in *. move: HInc. rewrite csum_included.
    case; first done. case; by intros (? & ? & ? & ? & ?). }
  simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
  rewrite to_agree_included. case=> /= ? ? _. simplify_eq.
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRsRestore]"; first done.
  rewrite bool_decide_true; last lia.
  iDestruct "HRR" as "(HIsSus & HTh' & HRR)". iDestruct "HRR" as (ℓ) "[#H↦ HRR]".
  iApply (aacc_aupd_commit with "AU"). by solve_ndisj. iIntros "HComplPermit".
  destruct r as [[| |r']|].
  - (* Cell could not have already been resumed. *)
    iDestruct "HRR" as "(_ & _ & #HCompleted & _)".
    iDestruct (future_completion_permit_implies_not_completed
                 with "HComplPermit HCompleted") as ">[]".
  - (* Cell was immediately cancelled. *)
    iDestruct "HRR" as "(Hℓ & >HImmediate & #HCancelled & HResources)".
    iDestruct "HImmediate" as %HImmediate.
    simpl. rewrite /resources_for_resumer.
    iDestruct "HResources" as "[[>[HContra|[HPermit' HIsRes]] HR]|[>HContra _]]".
    all: try by iDestruct (future_completion_permit_exclusive
                             with "HContra HComplPermit") as %[].
    iCombine "HComplPermit" "HPermit'" as "HComplPermit".
    iEval (rewrite -future_completion_permit_Fractional Qp_half_half)
      in "HComplPermit".
    iAssert (▷ V' #v ∨ ▷ future_is_cancelled γf')%I with "[]" as "HAacc'";
      first by iRight.
    iCombine "HAacc'" "HComplPermit" as "HAacc".
    iAaccIntro with "HAacc".
    { iIntros "[_ HComplPermit]".
      iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HComplPermit".
      iDestruct "HComplPermit" as "[$ HComplPermit]". iIntros "!> $".
      iFrame "HV". iModIntro.
      iExists _, _. iFrame "H● HLen HDeqIdx".
      iSpecialize ("HRRsRestore" $! _). rewrite list_insert_id //.
      iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦ HCancelled Hℓ".
      iSplitR; first done. iLeft. iFrame "HR". iRight. iFrame.
    }
    iIntros (r) "Hr". destruct r.
    by iDestruct (future_is_completed_not_cancelled
                    with "Hr HCancelled") as ">[]".
    iExists false.
    assert (immediateCancellation = true) as ->
        by destruct immediateCancellation=>//.
    iDestruct "Hr" as "(_ & _ & HComplPermit)". iFrame "HV HR".
    iIntros "!> $ !>". iExists _, _. iFrame.
    iSpecialize ("HRRsRestore" $! _). rewrite list_insert_id //.
    iApply "HRRsRestore". iFrame "HIsSus HTh'". iExists _.
    iFrame "H↦ HCancelled Hℓ".
    iSplitR. by destruct immediateCancellation. iRight. iFrame.
  - (* Cell was cancelled. *)
    iDestruct "HRR" as "(#HCancelled & >HNotImmediate & HRR)".
    iDestruct "HNotImmediate" as %HNotImmediate.
    iAssert (▷(future_completion_permit γf' 1%Qp ∗ iterator_issued γd i ∗
              ((iterator_issued γd i -∗ future_completion_permit γf' (1/2)%Qp -∗ cell_resources γtq γa γe γd i (Some (cellInhabited γf' f' (Some (cellCancelled r')))) true) ∧
               (future_completion_permit γf' 1%Qp -∗ cell_resources γtq γa γe γd i (Some (cellInhabited γf' f' (Some (cellCancelled r')))) true))))%I
      with "[HIsSus HTh' HRR HComplPermit]" as "(>HPermit & >HIsRes & HRestore)".
    {
      destruct r' as [[[[| ] | ] | ]|].
      - iDestruct "HRR" as "(_ & _ & >HContra)".
        iDestruct (future_completion_permit_exclusive
                     with "HContra HComplPermit") as "[]".
      - iDestruct "HRR" as "(Hℓ & HCancToken &
          [[>[HContra|[HComplPermit' HIsRes]] HAwak] | [>HContra _] ])".
        all: try iDestruct (future_completion_permit_exclusive
                              with "HContra HComplPermit") as "[]".
        iCombine "HComplPermit" "HComplPermit'" as "HComplPermit".
        rewrite -future_completion_permit_Fractional Qp_half_half.
        iFrame "HComplPermit HIsRes HIsSus HTh'". iSplit.
        + iNext. iIntros "HIsRes HComplPermit". iFrame. iExists _.
          iFrame "H↦ HCancelled Hℓ". iSplitR; first done. iLeft. iFrame. iRight.
          iFrame.
        + iNext. iIntros "HComplPermit". iFrame. iExists _.
          iFrame "H↦ HCancelled Hℓ". done.
      - iDestruct "HRR" as "(Hℓ & HE &
          [[>[HContra|[HComplPermit' HIsRes]] HAwak] | [>HContra _] ])".
        all: try iDestruct (future_completion_permit_exclusive
                              with "HContra HComplPermit") as "[]".
        iCombine "HComplPermit" "HComplPermit'" as "HComplPermit".
        rewrite -future_completion_permit_Fractional Qp_half_half.
        iFrame "HComplPermit HIsRes HIsSus HTh'". iSplit.
        + iNext. iIntros "HIsRes HComplPermit". iFrame. iExists _.
          iFrame "H↦ HCancelled Hℓ". iSplitR; first done. iLeft. iFrame. iRight.
          iFrame.
        + iNext. iIntros "HComplPermit". iFrame. iExists _.
          iFrame "H↦ HCancelled Hℓ". done.
      - iDestruct "HRR" as "($ & $ &
          [(Hℓ & HE & >[HC|[HComplPermit' HIsRes]])|[(Hℓ &
            [[>[HC|[HComplPermit' HIsRes]] HAwak] | [>HC _] ] & HTok)|HC']])";
          last iDestruct "HC'" as (?) "(_ & _ & _ & >HC & _)".
        all: try iDestruct (future_completion_permit_exclusive
                              with "HC HComplPermit") as "[]".
        all: iCombine "HComplPermit" "HComplPermit'" as "HComplPermit".
        all: rewrite -future_completion_permit_Fractional Qp_half_half.
        all: iFrame "HComplPermit HIsRes HIsSus HTh'".
        * iSplit.
          + iNext. iIntros "HIsRes HComplPermit". iFrame. iExists _.
            iFrame "H↦ HCancelled". iSplitR; first done. iLeft. iFrame. iRight.
            iFrame.
          + iNext. iIntros "HComplPermit". iExists _.
            iFrame "H↦ HCancelled". repeat (iSplitR; first done). iLeft. iFrame.
        * iSplit.
          + iNext. iIntros "HIsRes HComplPermit". iExists _.
            iFrame "H↦ HCancelled". repeat (iSplitR; first done).
            iRight. iLeft. iFrame. iLeft. iFrame. iRight. iFrame.
          + iNext. iIntros "HComplPermit". iExists _.
            iFrame "H↦ HCancelled".
            repeat (iSplitR; first done). iRight. iLeft. iFrame.
      - iDestruct "HRR" as "($ & $ & HRR)".
        iDestruct "HRR" as "[(Hℓ & HE & >[HC|[HComplPermit' HIsRes]])|
                            [_ HRR]]";
          last iDestruct "HRR" as (?) "(_ & _ & _ & >HC & _)".
        all: try iDestruct (future_completion_permit_exclusive
                              with "HC HComplPermit") as "[]".
        iCombine "HComplPermit" "HComplPermit'" as "HComplPermit".
        rewrite -future_completion_permit_Fractional Qp_half_half.
        iFrame "HComplPermit HIsRes HIsSus HTh'". iSplit.
        + iNext. iIntros "HIsRes HComplPermit". iFrame. iExists _.
          iFrame "H↦ HCancelled". iSplitR; first done. iLeft. iFrame. iRight.
          iFrame.
        + iNext. iIntros "HComplPermit". iExists _.
          iFrame "H↦ HCancelled". repeat (iSplitR; first done). iLeft. iFrame.
    }
    iAssert (▷ V' #v ∨ ▷ future_is_cancelled γf')%I with "[]" as "HAacc'";
      first by iRight.
    iCombine "HAacc'" "HPermit" as "HAacc".
    iAaccIntro with "HAacc".
    { iIntros "[_ HComplPermit]".
      iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HComplPermit".
      iDestruct "HComplPermit" as "[$ HComplPermit]". iIntros "!> $".
      iFrame "HV". iModIntro.
      iExists _, _. iFrame "H● HLen HDeqIdx".
      iSpecialize ("HRRsRestore" $! _). rewrite list_insert_id //.
      iApply "HRRsRestore". iDestruct "HRestore" as "[HRestore _]".
      iApply ("HRestore" with "[$] [$]").
    }
    iIntros (r) "Hr". destruct r.
    by iDestruct (future_is_completed_not_cancelled
                 with "Hr HCancelled") as ">[]".
    iDestruct "Hr" as "(_ & _ & HComplPermit)".
    iExists false. iFrame "HV". destruct immediateCancellation=>//.
    iMod (cancelled_cell_core_id_ra with "H●") as "[H● H◯']"; first done.
    iFrame "HIsRes". iSplitL "H◯'"; first by iExists _, _.
    iIntros "!> $ !>". iExists _, _. iFrame.
    iSpecialize ("HRRsRestore" $! _). rewrite list_insert_id //.
    iApply "HRRsRestore". iDestruct "HRestore" as "[_ HRestore]".
    iApply "HRestore". iFrame "HComplPermit".
  - (* Cell was neither resumed nor cancelled. *)
    iDestruct "HRR" as "(Hℓ & HCancHandle & HE & HR & >HCancPermit &
      >[HC|[HPermit HAwak]])".
    by iDestruct (future_completion_permit_exclusive with "HC HComplPermit")
      as %[].
    iCombine "HComplPermit" "HPermit" as "HPermit'".
    rewrite -future_completion_permit_Fractional Qp_half_half.
    iAssert (▷ V' #v ∨ ▷ future_is_cancelled γf')%I
      with "[HV HR]" as "HV'"; first by iLeft; iExists _; iFrame.
    iCombine "HV'" "HPermit'" as "HAacc".
    iAaccIntro with "HAacc".
    { iIntros "HAacc". iDestruct "HAacc" as "[[HV'|HContra] HComplPermit]".
      2: {
        iDestruct (future_cancellation_permit_implies_not_cancelled with
                  "HCancPermit HContra") as ">[]".
      }
      iDestruct "HV'" as (x) "(>HEq & HV & HR)". iDestruct "HEq" as %HEq.
      simplify_eq.
      iEval (rewrite -Qp_half_half future_completion_permit_Fractional)
        in "HComplPermit".
      iDestruct "HComplPermit" as "[$ HComplPermit]". iIntros "!> $".
      iFrame "HV". iModIntro.
      iExists _, _. iFrame "H● HLen HDeqIdx".
      iSpecialize ("HRRsRestore" $! _). rewrite list_insert_id //.
      iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦". iFrame. iRight. iFrame.
    }
    iIntros (r) "Hr". destruct r.
    2: {
      iDestruct "Hr" as "[Hr _]".
      iDestruct (future_cancellation_permit_implies_not_cancelled
                   with "HCancPermit Hr") as "[]".
    }
    iExists true. iDestruct "Hr" as "#HCompleted". iFrame "HCompleted HE".
    iMod (resume_cell_ra with "H●") as "[H● H◯']"; first done.
    iSplitL "H◯'". by iExists _, _.
    iIntros "!> $ !>".
    iDestruct "HLen" as %HLen. iDestruct "HDeqIdx" as %HDeqIdx.
    iExists _, _. iFrame "H●". rewrite insert_length. iSplitL.
    2: {
      iPureIntro. split; first lia.
      case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
      destruct (decide (i = deqFront - 1)).
      - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
        simpl in *. simplify_eq. contradiction.
      - rewrite list_lookup_insert_ne in HEl'; last lia.
      eexists. done.
    }
    iApply "HRRsRestore". iFrame. iExists _. iFrame "H↦ HCompleted".
    by iLeft.
Qed.

Lemma await_cell γa γtq γe γd e d γf f i:
  NTq ## NFuture ->
  is_thread_queue γa γtq γe γd e d -∗
  rendezvous_thread_handle γtq γf f i -∗
  <<< future_cancellation_permit γf (1/2)%Qp >>>
    awaitFuture f @ ⊤ ∖ ↑NFuture ∖ ↑NTq
  <<< ∃ (v': base_lit), V v' ∗ R ∗ future_is_completed γf #v',
      RET (SOMEV #v') >>>.
Proof.
  iIntros (HMask) "[#HInv _] #[HFuture H◯]". iIntros (Φ) "AU".
  awp_apply (awaitFuture_spec with "HFuture").
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct (rendezvous_state_included' with "H● H◯")
    as %(c & HEl & HInc).
  destruct c as [? ?|? ? r].
  { exfalso. simpl in *. move: HInc. rewrite csum_included.
    case; first done. case; by intros (? & ? & ? & ? & ?). }
  simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
  rewrite to_agree_included. case=> /= ? ? _. simplify_eq.
  iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
    first done.
  simpl.
  iDestruct "HRR" as "(HIsSus & HTh' & HRR)". iDestruct "HRR" as (ℓ) "[#H↦ HRR]".
  iApply (aacc_aupd_commit with "AU"). by solve_ndisj. iIntros "HCancPermit".
  destruct r as [[| |]|].
  (* Could not have been cancelled: we hold the permit. *)
  2: iDestruct "HRR" as "(_ & _ & HContra & _)".
  3: iDestruct "HRR" as "[HContra _]".
  all: try by iDestruct (future_cancellation_permit_implies_not_cancelled
                           with "HCancPermit HContra") as ">[]".
  - (* Cell was already resumed. *)
    iDestruct "HRR" as "(Hℓ & HIsRes & #HCompleted & HCancHandle & >HPermit)".
    iCombine "HCancPermit" "HPermit" as "HPermit'".
    rewrite -future_cancellation_permit_Fractional Qp_half_half.
    iAaccIntro with "HPermit'".
    { iIntros "HCancPermit !>".
      iEval (rewrite -Qp_half_half future_cancellation_permit_Fractional)
        in "HCancPermit".
      iDestruct "HCancPermit" as "[$ HPermit]". iIntros "$ !>".
      iExists _, _. iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame. }
    iIntros (r) "(HV & #HCompleted' & HCancPermit)".
    iDestruct "HV" as (? HEq) "[HV HR]". simplify_eq. iExists _.
    iFrame "HV HR HCompleted'". iModIntro. iIntros "$ !>".
    iExists _, _. iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
    iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame.
  - (* Cell was neither resumed nor cancelled. *)
    iDestruct "HRR" as "(Hℓ & HCancHandle & HE & HR & >HPermit & HRR)".
    iCombine "HCancPermit" "HPermit" as "HPermit'".
    rewrite -future_cancellation_permit_Fractional Qp_half_half.
    iAaccIntro with "HPermit'".
    { iIntros "HCancPermit !>".
      iEval (rewrite -Qp_half_half future_cancellation_permit_Fractional)
        in "HCancPermit".
      iDestruct "HCancPermit" as "[$ HPermit]". iIntros "$ !>".
      iExists _, _. iFrame "H● HLen HDeqIdx". iApply "HRRsRestore". simpl.
      iFrame "HIsSus HTh'". iExists _. iFrame "H↦". by iFrame. }
    iIntros (r) "(_ & HContra & _)".
    iDestruct "HRR" as "[>HC|[>HC _]]".
    all: iDestruct (future_completion_permit_implies_not_completed
                      with "HC HContra") as %[].
Qed.

(* MARKING STATES **************************************************************)

Lemma mark_cell_as_resumed γa γtq γe γd e d i ptr v:
  {{{ is_thread_queue γa γtq γe γd e d ∗
      inhabited_rendezvous_state γtq i (Some (Cinl (to_agree #v))) ∗
      cell_location γtq γa i ptr }}}
    #ptr <- RESUMEDV
  {{{ RET #(); True }}}.
Proof.
  iIntros (Φ) "([#HInv _] & #HResumed & #H↦) HΦ".
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct "HResumed" as (γf' f') "HResumed".
  iDestruct (rendezvous_state_included' with "H● HResumed")
            as %(c & HEl & HInc).
  destruct c as [? ?|γf f r].
  { exfalso. simpl in *. move: HInc. rewrite csum_included.
    case; first done. case; by intros (? & ? & ? & ? & ?). }
  simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
  rewrite to_agree_included. case=> /= ? ? HInc'. simplify_eq.
  destruct r as [r'|]; last by apply included_None in HInc'. simpl in *.
  destruct r' as [v'| |]; simpl in *.
  - iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRsRestore]";
      first done.
    simpl. iDestruct "HRR" as "(HIsSus & HTh' & HRR)".
    iDestruct "HRR" as (?) "(H↦' & Hℓ & HRR)".
    iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
    iAssert (▷ ptr ↦ -)%I with "[Hℓ]" as (?) "Hℓ".
    { iDestruct "Hℓ" as "[Hℓ|Hℓ]"; by iExists _. }
    wp_store.
    iDestruct ("HΦ" with "[$]") as "$". iModIntro. iExists _, _.
    iFrame. iApply "HRRsRestore". iFrame. iExists _. iFrame "H↦ Hℓ".
  - exfalso. move: HInc'. rewrite Some_included; case.
    by move=> HInc; inversion HInc.
    rewrite csum_included. case; first done. case; by intros (? & ? & ? & ? & ?).
  - exfalso. move: HInc'. rewrite Some_included; case.
    by move=> HInc; inversion HInc.
    rewrite csum_included. case; first done. case; by intros (? & ? & ? & ? & ?).
Qed.

Theorem register_cancellation E' γa γtq γe γd e d n i:
  ↑NTq ⊆ E' ->
  is_thread_queue γa γtq γe γd e d -∗
  cancellation_registration_token γtq i -∗
  thread_queue_state γtq n ={E'}=∗
  cell_cancelling_token γtq i ∗
  if bool_decide (n = 0)
  then thread_queue_state γtq 0 ∗ ▷ R ∗
       inhabited_rendezvous_state γtq i
         (Some (Cinr (Cinr (0, Some (Cinl (to_agree ()))))))
  else thread_queue_state γtq (n - 1) ∗ ▷ cancellation_handle γa i ∗
       inhabited_rendezvous_state γtq i
         (Some (Cinr (Cinr (0, Some (Cinr ε))))).
Proof.
  iIntros (HMask) "[#HInv _] HToken H◯". iDestruct "HToken" as (? ?) "HToken".
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)" "HClose".
  iDestruct (rendezvous_state_included' with "H● HToken") as %(c & HEl & HInc).
  assert (c = cellInhabited γf f (Some (cellCancelled None))) as ->.
  {
    destruct c as [|? ? r]=>//=.
    { exfalso. simpl in *. move: HInc. rewrite csum_included.
      case; first done. case; by intros (? & ? & ? & ? & ?). }
    simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
    rewrite to_agree_included. case=> /= ? ? HInc'. simplify_eq.
    destruct r as [r'|]; last by apply included_None in HInc'. simpl in *.
    move: HInc'.
    destruct r' as [v'| |r'']; simpl in *.
    - rewrite Some_included. case. by intros HContra; inversion HContra.
      rewrite csum_included. case; first done.
      case; by intros (? & ? & ? & ? & ?).
    - rewrite Some_included. rewrite Cinr_included. case.
      + intros HContra. inversion HContra. simplify_eq.
        inversion H5.
      + rewrite csum_included. case; first done.
        case; by intros (? & ? & ? & ? & ?).
    - destruct r'' as [|].
      { simpl. rewrite Some_included. case.
        { move=> HCinr. apply Cinr_inj in HCinr. apply Cinr_inj in HCinr.
          move: HCinr. case. simpl. done. }
        rewrite Cinr_included Cinr_included prod_included /= nat_included.
        case; lia. }
      done.
  }
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRs]"; first done.
  simpl. iDestruct "HRR" as "(HIsSus & HTh & HRR)".
  iDestruct "HRR" as (ℓ) "(H↦ & HFutureCancelled & HNotImmediate & HRR)".
  iDestruct "HRR" as "(HCancHandle & HR & HContents)".
  iDestruct (thread_queue_state_valid with "H● H◯") as %->.
  remember (count_matching _ _) as n eqn:HCountMatching.
  destruct n.
  - (* There are no cells left to awaken. *)
    destruct (decide (deqFront ≤ i)) as [?|HLeDeqFront].
    { (* Impossible: we know that there are no alive cells, but we are alive. *)
      exfalso.
      assert (∃ k, drop deqFront l !! (i - deqFront) = Some k ∧
                   is_nonskippable k) as (k & HEl' & HNonSkippable).
      { eexists. rewrite lookup_drop. replace (_ + (_ - _)) with i by lia.
        by split. }
      symmetry in HCountMatching. move: HCountMatching.
      rewrite count_matching_none. move=> HCountMatching.
      assert (¬ is_nonskippable k); last contradiction.
      apply HCountMatching, elem_of_list_lookup. eauto. }
    iMod (abandon_cell_ra with "H● [HToken]")
      as "(H● & HToken & HAbandoned)"; first done.
    { by iExists _, _. }
    rewrite bool_decide_true; last lia.
    rewrite bool_decide_true; last lia.
    iFrame "H◯ HR".
    iMod ("HClose" with "[-HToken HAbandoned]") as "_".
    {
      iExists _, _. iFrame "H●". rewrite insert_length.
      iDestruct "HLen" as %HLen. iDestruct "HDeqIdx" as %HDeqIdx.
      iSplitL.
      2: {
        iPureIntro. split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx.
        split; first done. destruct (decide (i = deqFront - 1)).
        - subst. rewrite list_insert_alter list_lookup_alter HEl in HEl'.
          simpl in *. simplify_eq. contradiction.
        - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRs". iFrame "HIsSus HTh". iExists _.
      iFrame "H↦ HFutureCancelled HNotImmediate HCancHandle".
      iDestruct "HContents" as "[HContents|HContents]"; first by iLeft.
      iDestruct "HContents" as "[_ HContents]". iRight. iRight. done.
    }
    iModIntro. iSplitL "HToken"; iExists _, _; iFrame.
  - (* We may defer our awakening to another cell. *)
    iEval (rewrite bool_decide_false; last lia). iFrame "HCancHandle".
    destruct (decide (deqFront ≤ i)) as [HGeDeqFront|HLtDeqFront].
    + iMod (allow_cell_cancellation_outside_deqFront_ra with "H● H◯ [HToken]")
           as "(H● & $ & HCancellingToken & #HState)"; try done.
      by iExists _, _.
      iMod ("HClose" with "[-HCancellingToken]") as "_".
      2: iModIntro; iSplitL; by iExists _, _.
      iExists _, _. iFrame "H●". rewrite insert_length.
      iDestruct "HLen" as %HLen; iDestruct "HDeqIdx" as %HDeqIdx.
      iSplitL.
      2: {
        iPureIntro. split; first lia.
        case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
        destruct (decide (i = deqFront - 1)). by lia.
        rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
      }
      iApply "HRRs". rewrite bool_decide_false; last lia.
      simpl. iFrame "HIsSus HTh". iExists _.
      iFrame "H↦ HFutureCancelled HNotImmediate".
      iDestruct "HContents" as "[($ & $ & HContents)|[>% _]]"; last lia.
      iLeft. iFrame.
    + rewrite bool_decide_true; last lia.
      assert (is_Some (find_index is_nonskippable (drop deqFront l)))
             as [j HFindSome].
      { apply count_matching_find_index_Some. lia. }
      iMod (allow_cell_cancellation_inside_deqFront_ra with "H● H◯ [HToken]")
           as "(H● & HAwaks & $ & #HDeqFront & HCancellingToken & #HState)";
        try done.
      by rewrite drop_insert_gt; last lia.
      lia.
      by iExists _, _.
      iDestruct "HContents" as "[HContents|[_ HContents]]".
      * iMod ("HClose" with "[-HCancellingToken]") as "_".
        2: iModIntro; iSplitL; by iExists _, _.
        iExists _, _. iFrame "H●".
        iDestruct "HLen" as "_"; iDestruct "HDeqIdx" as "_".
        iSplitL.
        simpl. iDestruct "HAwaks" as "[HAwak HAwaks]".
        iDestruct ("HRRs" $! (Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed None))))))
                    with "[-HAwaks HR]") as "HRRs".
        { iFrame. iExists _. iFrame.
          iDestruct "HContents" as "($ & $ & HFuture)". iLeft. iFrame. }
        iDestruct (advance_deqFront with "HAwaks HR HRRs") as "$".
        by rewrite drop_insert_gt; last lia.
        iPureIntro. apply advance_deqFront_pure.
        by rewrite drop_insert_gt; last lia.
      * iDestruct "HContents" as (v) "(HUnboxed & Hℓ & HIsres & HFuture & HV)".
        iMod (put_value_in_cancelled_cell_ra v with "H●")
             as "[H● #HState']".
        { erewrite list_lookup_insert. done.
          by eapply lookup_lt_Some. }
        rewrite list_insert_insert.
        iMod ("HClose" with "[-HCancellingToken]") as "_".
        2: iModIntro; iSplitL; by iExists _, _.
        iExists _, _. iFrame "H●".
        iDestruct "HLen" as "_"; iDestruct "HDeqIdx" as "_".
        iSplitL.
        simpl. iDestruct "HAwaks" as "[HAwak HAwaks]".
        iDestruct ("HRRs" $! (Some (cellInhabited γf f (Some (cellCancelled (Some (cancellationAllowed (Some (cellTookValue v))))))))
                    with "[-HAwaks HR]") as "HRRs".
        { iFrame. iExists _. iFrame "H↦". iLeft. iFrame. }
        iDestruct (advance_deqFront with "HAwaks HR HRRs") as "$".
        by rewrite drop_insert_gt; last lia.
        iPureIntro. apply advance_deqFront_pure.
        by rewrite drop_insert_gt; last lia.
Qed.

Lemma markCancelled_spec γa γtq γe γd e d i ptr γf f:
  ∀ Φ,
  is_thread_queue γa γtq γe γd e d
  ∗ inhabited_rendezvous_state γtq i (Some (Cinr (Cinr (0, Some (Cinr ε)))))
  ∗ cell_location γtq γa i ptr
  ∗ cell_cancelling_token γtq i
  ∗ rendezvous_thread_handle γtq γf f i
  -∗ ▷ (∀ v : val,
          ⌜v = InjLV f⌝ ∧ E
          ∨ (∃ v' : base_lit,
            ⌜v = InjRV #v'⌝
            ∧ inhabited_rendezvous_state γtq i
                (Some (Cinr (Cinr (0, Some (Cinr (Some (Cinl (to_agree #v'))))))))
            ∗ awakening_permit γtq
            ∗ V v') -∗ Φ v) -∗ WP getAndSet #ptr CANCELLEDV {{ v, ▷ Φ v }}.
Proof.
  iIntros (Φ) "([#HInv _] & #HState & #H↦ & HToken & #HTh) HΦ".
  iDestruct "HToken" as (? ?) "HToken".
  awp_apply getAndSet_spec.
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct "HState" as (γf' f') "HState".
  iDestruct (rendezvous_state_included' with "H● HState") as %(c & HEl & HInc).
  assert (∃ d, c = cellInhabited γf' f' (Some (cellCancelled (Some (cancellationAllowed d))))) as [d' ->].
  {
    destruct c as [|? ? r]=>//=.
    { exfalso. simpl in *. move: HInc. rewrite csum_included.
      case; first done. case; by intros (? & ? & ? & ? & ?). }
    simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
    rewrite to_agree_included. case=> /= ? ? HInc'. simplify_eq.
    destruct r as [r'|]; last by apply included_None in HInc'. simpl in *.
    move: HInc'.
    destruct r' as [v'| |r'']; simpl in *.
    - rewrite Some_included. case. by intros HContra; inversion HContra.
      rewrite csum_included. case; first done.
      case; by intros (? & ? & ? & ? & ?).
    - rewrite Some_included. rewrite Cinr_included. case.
      + intros HContra. inversion HContra. simplify_eq.
        inversion H5.
      + rewrite csum_included. case; first done.
        case; by intros (? & ? & ? & ? & ?).
    - destruct r'' as [r'''|].
      2: { simpl. rewrite Some_included. case.
        { move=> HCinr. apply Cinr_inj in HCinr. apply Cinr_inj in HCinr.
          move: HCinr. case. simpl. done. }
        rewrite Cinr_included Cinr_included prod_included /= nat_included.
        case=> _ HContra. by apply included_None in HContra. }
      destruct r'''.
      2: {
        simpl. rewrite Some_included. case.
        { move=> HCinr. apply Cinr_inj in HCinr. apply Cinr_inj in HCinr.
          move: HCinr. case. simpl. done. }
        rewrite Cinr_included Cinr_included prod_included /= nat_included.
        rewrite Some_included. case=> _. case.
        intros HContra; by inversion HContra.
        rewrite csum_included.
        case; first done. case; by intros (? & ? & ? & ? & ?).
      }
      simpl. by eexists.
  }
  iDestruct (big_sepL_insert_acc with "HRRs") as "[HRR HRRs]"; first done.
  simpl. iDestruct "HRR" as "(HIsSus & #HTh' & HRR)".
  iDestruct "HTh" as "[HFutureLoc HTh]".
  iDestruct (rendezvous_state_included' with "H● HTh")
    as %(c' & HEl' & HInc').
  simplify_eq. simpl in *. move: HInc'. rewrite Cinr_included pair_included.
  rewrite to_agree_included. case. case=> /= HH1 HH2 _. simplify_eq.
  iDestruct "HRR" as (ℓ) "(H↦' & HFutureCancelled & HNotImmediate & HRR)".
  iAssert (own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
           cell_cancelling_token γtq i -∗
           cell_cancelling_token γtq i -∗ False)%I with "[]" as "HNotFinished".
  {
    iIntros "H● HToken HToken'".
    iDestruct "HToken" as (? ?) "HToken". iDestruct "HToken'" as (? ?) "HToken'".
    iCombine "HToken" "HToken'" as "HToken". rewrite list_singletonM_op.
    iDestruct (rendezvous_state_included' with "H● HToken")
      as %(c''' & HEl'' & HInc'').
    exfalso. simplify_eq. simpl in *.
    move: HInc''. rewrite -Cinr_op Cinr_included pair_included. case=> _/=.
    rewrite Some_included. case.
    - move=> HContra. do 2 apply Cinr_inj in HContra. case HContra.
      simpl. by case.
    - do 2 rewrite Cinr_included. rewrite pair_included. case=> /=.
      rewrite nat_included nat_op_plus. lia.
  }
  iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
  destruct d' as [[|]|].
  2: { (* Only we could have finished the cancellation. *)
    iDestruct "HRR" as "(_ & >HToken' & _)".
    iDestruct ("HNotFinished" with "H● HToken' [HToken]") as %[].
    by iExists _, _.
  }
  - (* a value was passed to the cell. *)
    iDestruct "HRR" as "([(Hℓ & >HUnboxed & HV & HAwak)|(_ & >HToken')] &
                        HIsRes & HFuture)".
    2: { iDestruct ("HNotFinished" with "H● HToken' [HToken]") as %[].
         by iExists _, _. }
    iDestruct "HUnboxed" as %HUnboxed.
    iAssert (▷ ptr ↦ InjRV #v ∧ ⌜val_is_unboxed (InjRV #v)⌝)%I
            with "[Hℓ]" as "HAacc"; first by iFrame.
    iAaccIntro with "HAacc".
    { iIntros "[Hℓ _] !>". iFrame "HToken HΦ". iExists _, _.
      iSpecialize ("HRRs" $! _). rewrite list_insert_id; last done.
      iFrame "H● HLen HDeqIdx". iApply "HRRs". iFrame "HIsSus HTh'".
      iExists _. iFrame "H↦". iFrame "HFutureCancelled HNotImmediate".
      iFrame "HIsRes HFuture". iLeft. by iFrame. }
    iIntros "Hℓ".
    iMod (own_update with "H●") as "[H● H◯]".
    2: iSplitR "HΦ H◯ HV HAwak".
    3: { iModIntro; iNext.
      iApply "HΦ". iRight; iExists _. iFrame "HV HAwak". iSplitR; first done.
      iExists _, _. iFrame. }
    {
      apply auth_update_core_id. apply _. apply prod_included. simpl.
      split; first by apply ucmra_unit_least. apply prod_included. simpl.
      split; last by apply ucmra_unit_least. apply list_singletonM_included.
      eexists. rewrite map_lookup HEl=> /=. split; first done.
      apply Some_included. right. apply Cinr_included. apply prod_included'.
      split=> /=; first done. apply Some_included. right.
      do 2 apply Cinr_included. apply prod_included=> /=. split; last done.
      apply nat_included. lia.
    }
    iSpecialize ("HRRs" $! _). rewrite list_insert_id; last done.
    iModIntro.
    iExists _, _. iFrame. iApply "HRRs". iFrame. iFrame "HTh'". iExists _.
    iFrame "H↦". iRight. iFrame "Hℓ". by iExists _, _.
  - (* we may cancel the cell without obstructions. *)
    iDestruct (future_is_loc with "HFutureLoc") as %[fℓ ->].
    iDestruct "HRR" as "(Hℓ & HE & HRR)".
    iAssert (▷ ptr ↦ InjLV #fℓ ∧ ⌜val_is_unboxed (InjLV #fℓ)⌝)%I
      with "[Hℓ]" as "HAacc"; first by iFrame.
    iAaccIntro with "HAacc".
    { iIntros "[Hℓ _] !>". iFrame "HToken HΦ". iExists _, _.
      iSpecialize ("HRRs" $! _). rewrite list_insert_id; last done.
      iFrame "H● HLen HDeqIdx". iApply "HRRs". iFrame "HIsSus HTh'".
      iExists _. iFrame "H↦". iFrame "HFutureCancelled HNotImmediate".
      iFrame "Hℓ HE HRR". }
    iIntros "Hℓ".
    iMod (finish_cancellation_ra with "H●") as "[H● #H◯]"; first done.
    iModIntro. iSplitR "HΦ HE".
    2: { iNext. iApply "HΦ". iLeft. by iFrame. }
    iExists _, _. iFrame "H●". rewrite insert_length.
    iDestruct "HLen" as %HLen; iDestruct "HDeqIdx" as %HDeqIdx.
    iSplitL.
    2: {
      iPureIntro. split; first lia.
      case. intros ? (r & HEl' & HSkippable). apply HDeqIdx. split; first done.
      destruct (decide (i = deqFront - 1)) as [->|HNeq].
      - rewrite list_lookup_insert in HEl'; last lia. simplify_eq.
        eexists. by split.
      - rewrite list_lookup_insert_ne in HEl'; last lia.
        eexists. done.
    }
    iApply "HRRs". iFrame "HIsSus HTh'". iExists _.
    iFrame "H↦ HFutureCancelled HNotImmediate Hℓ". iSplitL "HToken".
    by iExists _, _.
    rewrite /resources_for_resumer.
    iDestruct "HRR" as "[[H1 H2]|(H1 & H2 & _)]"; [iLeft|iRight]; iFrame.
Qed.

Lemma markRefused_spec γa γtq γe γd e d i ptr γf f:
  ∀ Φ,
  is_thread_queue γa γtq γe γd e d
  ∗ inhabited_rendezvous_state γtq i (Some (Cinr (Cinr (0, Some (Cinl (to_agree ()))))))
  ∗ cell_location γtq γa i ptr
  ∗ cell_cancelling_token γtq i
  ∗ rendezvous_thread_handle γtq γf f i
  ∗ ▷ ERefuse
  -∗ ▷ (∀ v : val,
    ⌜v = InjLV f⌝ ∧ E
    ∨ (∃ v' : base_lit,
      ⌜v = InjRV #v'⌝
      ∗ ERefuse
      ∗ V v') -∗ Φ v) -∗ WP getAndSet #ptr REFUSEDV {{ v, ▷ Φ v }}.
Proof.
  iIntros (Φ) "([#HInv _] & #HState & #H↦ & HToken & #HTh & HERefuse) HΦ".
  iDestruct "HToken" as (? ?) "HToken".
  awp_apply getAndSet_spec.
  iInv "HInv" as (l deqFront) "(>H● & HRRs & >HLen & >HDeqIdx)".
  iDestruct "HState" as (γf' f') "HState".
  iDestruct (rendezvous_state_included' with "H● HState") as %(c & HEl & HInc).
  assert (c = cellInhabited γf' f' (Some (cellCancelled (Some cancellationPrevented)))) as ->.
  {
    destruct c as [|? ? r]=>//=.
    { exfalso. simpl in *. move: HInc. rewrite csum_included.
      case; first done. case; by intros (? & ? & ? & ? & ?). }
    simpl in *. move: HInc. rewrite Cinr_included pair_included. case.
    rewrite to_agree_included. case=> /= ? ? HInc'. simplify_eq.
    destruct r as [r'|]; last by apply included_None in HInc'. simpl in *.
    move: HInc'.
    destruct r' as [v'| |r'']; simpl in *.
    - rewrite Some_included. case. by intros HContra; inversion HContra.
      rewrite csum_included. case; first done.
      case; by intros (? & ? & ? & ? & ?).
    - rewrite Some_included. rewrite Cinr_included. case.
      + intros HContra. inversion HContra. simplify_eq.
        inversion H5.
      + rewrite csum_included. case; first done.
        case; by intros (? & ? & ? & ? & ?).
    - destruct r'' as [r'''|].
      2: { simpl. rewrite Some_included. case.
        { move=> HCinr. apply Cinr_inj in HCinr. apply Cinr_inj in HCinr.
          move: HCinr. case. simpl. done. }
        rewrite Cinr_included Cinr_included prod_included /= nat_included.
        case=> _ HContra. by apply included_None in HContra. }
      destruct r'''; last done.
      {
        simpl. rewrite Some_included. case.
        { move=> HCinr. apply Cinr_inj in HCinr. apply Cinr_inj in HCinr.
          move: HCinr. case. simpl. done. }
        rewrite Cinr_included Cinr_included prod_included /= nat_included.
        rewrite Some_included. case=> _. case.
        intros HContra; by inversion HContra.
        rewrite csum_included.
        case; first done. case; by intros (? & ? & ? & ? & ?).
      }
  }
  iDestruct (big_sepL_lookup_acc with "HRRs") as "[HRR HRRs]"; first done.
  simpl. iDestruct "HRR" as "(HIsSus & #HTh' & HRR)".
  iDestruct "HTh" as "[HFutureLoc HTh]".
  iDestruct (rendezvous_state_included' with "H● HTh")
    as %(c' & HEl' & HInc').
  simplify_eq. simpl in *. move: HInc'. rewrite Cinr_included pair_included.
  rewrite to_agree_included. case. case=> /= HH1 HH2 _. simplify_eq.
  iDestruct "HRR" as (ℓ) "(H↦' & HFutureCancelled & HNotImmediate & HRR)".
  iAssert (own γtq (cell_list_contents_auth_ra γa γe γd l deqFront) -∗
           cell_cancelling_token γtq i -∗
           cell_cancelling_token γtq i -∗ False)%I with "[]" as "HNotFinished".
  {
    iIntros "H● HToken HToken'".
    iDestruct "HToken" as (? ?) "HToken". iDestruct "HToken'" as (? ?) "HToken'".
    iCombine "HToken" "HToken'" as "HToken". rewrite list_singletonM_op.
    iDestruct (rendezvous_state_included' with "H● HToken")
      as %(c''' & HEl'' & HInc'').
    exfalso. simplify_eq. simpl in *.
    move: HInc''. rewrite -Cinr_op Cinr_included pair_included. case=> _/=.
    rewrite Some_included. case.
    - move=> HContra. do 2 apply Cinr_inj in HContra. case HContra.
      simpl. by case.
    - do 2 rewrite Cinr_included. rewrite pair_included. case=> /=.
      rewrite nat_included nat_op_plus. lia.
  }
  iDestruct (infinite_array_mapsto_agree with "H↦ H↦'") as "><-".
  iDestruct "HRR" as "(HInside & HCancHandle & HRR)".
  iDestruct "HRR" as "[(Hℓ & HE & HRes)|[(_ & _ & HToken')|HRR]]".
  2: { (* Only we could have finished the cancellation. *)
    iDestruct ("HNotFinished" with "H● HToken' [HToken]") as ">[]".
    by iExists _, _.
  }
  - (* we may mark the cell as refused without obstructions. *)
    iDestruct (future_is_loc with "HFutureLoc") as %[fℓ ->].
    iAssert (▷ ptr ↦ InjLV #fℓ ∧ ⌜val_is_unboxed (InjLV #fℓ)⌝)%I
      with "[Hℓ]" as "HAacc"; first by iFrame.
    iAaccIntro with "HAacc".
    { iIntros "[Hℓ _] !>". iFrame "HToken HΦ HERefuse". iExists _, _.
      iFrame "H● HLen HDeqIdx". iApply "HRRs". iFrame "HIsSus HTh'".
      iExists _. iFrame "H↦". iFrame "HFutureCancelled HNotImmediate".
      iFrame "HInside HCancHandle". iLeft. iFrame. }
    iIntros "Hℓ". iModIntro. iSplitR "HΦ HE".
    2: { iNext. iApply "HΦ". iLeft. by iFrame. }
    iExists _, _. iFrame "H● HLen HDeqIdx".
    iApply "HRRs". iFrame "HIsSus HTh'". iExists _.
    iFrame "H↦ HFutureCancelled HNotImmediate HInside HCancHandle".
    iRight. iLeft. iFrame "Hℓ". iSplitR "HToken"; last by iExists _, _.
    iLeft. iFrame.
  - (* a value was passed to the cell *)
    iDestruct "HRR" as (v) "(>HUnboxed & Hℓ & HIsRes & HFuture & HV)".
    iDestruct "HUnboxed" as %HUnboxed.
    iAssert (▷ ptr ↦ InjRV #v ∧ ⌜val_is_unboxed (InjRV #v)⌝)%I
            with "[Hℓ]" as "HAacc"; first by iFrame.
    iAaccIntro with "HAacc".
    { iIntros "[Hℓ _] !>". iFrame "HToken HΦ HERefuse". iExists _, _.
      iFrame "H● HLen HDeqIdx". iApply "HRRs". iFrame "HIsSus HTh'".
      iExists _. iFrame "H↦".
      iFrame "HFutureCancelled HNotImmediate HInside HCancHandle".
      iRight. iRight. iExists _. by iFrame. }
    iIntros "Hℓ". iModIntro. iSplitR "HERefuse HV HΦ".
    2: { iApply "HΦ"; iRight. iExists _. by iFrame. }
    iExists _, _. iFrame "H● HLen HDeqIdx". iApply "HRRs".
    iFrame "HIsSus HTh'". iExists _.
    iFrame "H↦ HFutureCancelled HNotImmediate HInside HCancHandle".
    iRight. iLeft. iFrame "Hℓ". iSplitR "HToken"; last by iExists _, _.
    iRight. iFrame.
Qed.

(* TODO: *)
(* Passing a value in async cancellation mode *)
(* Taking the resumer resource from an immediately cancelled cell *)

Theorem try_deque_thread_spec E R γa γtq γe γd (eℓ epℓ dℓ dpℓ: loc):
  ▷ awakening_permit γtq -∗
  <<< ∀ l deqFront, ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront >>>
  ((try_deque_thread segment_size) #dpℓ) #dℓ @ ⊤ ∖ ↑N
  <<< ∃ (v: val), ▷ E ∗ (∃ i,
     (⌜l !! i = Some None⌝ ∧ ⌜v = #()⌝ ∧
                     ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ
                            (<[i := Some cellFilled]> l) deqFront) ∗
                            rendezvous_filled γtq i ∨
   ∃ γt (th: loc),
       ▷ rendezvous_thread_handle γtq γt th i ∗ (
      ⌜l !! i = Some (Some (cellInhabited γt th None))⌝ ∧ ⌜v = #th⌝ ∧
      ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ
        (<[i := Some (cellInhabited γt th (Some cellResumed))]> l)
        deqFront ∗ rendezvous_resumed γtq i ∗ resumer_token γtq i ∨

      ⌜l !! i = Some (Some (cellInhabited γt th (Some (cellCancelled None))))⌝ ∗
      rendezvous_cancelled γtq i ∨
      ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ
        (<[i := Some (cellInhabited γt th (Some (cellCancelled (Some cancellationPrevented))))]> l) deqFront ∗
      thread_doesnt_have_permits γt ∨

      (⌜l !! i = Some (Some (cellInhabited γt th (Some (cellCancelled (Some cancellationFinished)))))⌝ ∗
      rendezvous_cancelled γtq i ∨
       ⌜l !! i = Some (Some (cellInhabited γt th (Some cellAbandoned)))⌝ ∗
      rendezvous_abandoned γtq i) ∗
      ⌜v = #th⌝ ∧
      ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront ∗
      thread_doesnt_have_permits γt
  )), RET v >>>.
Proof.
  iIntros "HAwaken" (Φ) "AU". iLöb as "IH".
  wp_lam. wp_pures.

  awp_apply (increase_deqIdx with "HAwaken").
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? ?) "HTq".
  iAaccIntro with "HTq".
  by iIntros "$ !> $".
  iIntros (d ?) "($ & HIsRes & #HSegLoc) !> AU !>".

  wp_pures.

  wp_bind (segment_cutoff _).
  iDestruct (iterator_issued_implies_bound with "HIsRes") as "#HDAtLeast".
  awp_apply move_head_forward_spec.
  2: iApply (aacc_aupd_abort with "AU"); first done.
  2: iIntros (? ?) "(HInfArr & HRest)".
  2: iDestruct (is_segment_by_location_prev with "HSegLoc HInfArr")
    as (?) "[HIsSeg HArrRestore]".
  2: iDestruct "HIsSeg" as (?) "HIsSeg".
  2: iAaccIntro with "HIsSeg".
  {
    iApply big_sepL_forall. iIntros (k d' HEl). simpl.
    by iRight.
  }
  {
    iIntros "HIsSeg".
    iDestruct ("HArrRestore" with "HIsSeg") as "$".
    iFrame.
    by iIntros "!> $ !>".
  }
  iIntros "HIsSeg".
  iDestruct ("HArrRestore" with "[HIsSeg]") as "$"; first by iFrame.
  iFrame.
  iIntros "!> AU !>".

  wp_pures.

  awp_apply iterator_move_ptr_forward_spec; try iAssumption.
  {
    iPureIntro.
    move: (Nat.mul_div_le d (Pos.to_nat segment_size)).
    lia.
  }
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? ?) "(HInfArr & HListContents & >% & HRest)".
  iDestruct "HRest" as (? ?) "(HEnqIt & >HDeqIt & HRest)".
  iCombine "HInfArr" "HDeqIt" as "HAacc".
  iAaccIntro with "HAacc".
  {
    iIntros "[$ HDeqIt] !>". iFrame "HListContents".
    iSplitR "HIsRes". iSplitR; first done. iExists _, _. iFrame.
    by iIntros "$ !>".
  }
  iIntros "[$ HDeqPtr] !>".
  iSplitR "HIsRes".
  {
    iFrame "HListContents". iSplitR; first done.
    iExists _, _. iFrame.
  }
  iIntros "AU !>".

  wp_pures. wp_lam. wp_pures.

  replace (Z.rem d (Pos.to_nat segment_size)) with
      (Z.of_nat (d `mod` Pos.to_nat segment_size)).
  2: {
    destruct (Pos.to_nat segment_size) eqn:S; first by lia.
    by rewrite rem_of_nat.
  }
  awp_apply segment_data_at_spec.
  { iPureIntro. apply Nat.mod_upper_bound. lia. }
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? deqFront) "(HInfArr & HRest)".
  iDestruct (is_segment_by_location with "HSegLoc HInfArr")
    as (? ?) "[HIsSeg HArrRestore]".
  iAaccIntro with "HIsSeg".
  {
    iIntros "HIsSeg".
    iDestruct ("HArrRestore" with "HIsSeg") as "$".
    iFrame "HRest".
    by iIntros "!> $ !>".
  }
  iIntros (?) "(HIsSeg & #HArrMapsto & #HCellInv)".
  iDestruct ("HArrRestore" with "[HIsSeg]") as "$"; first done.
  iDestruct "HRest" as "((HLen & HRes & >HAuth & HRest') & HRest)".
  iMod (own_update with "HAuth") as "[HAuth HFrag']".
  2: iAssert (deq_front_at_least γtq deqFront) with "HFrag'" as "HFrag".
  {
    apply auth_update_core_id.
    by repeat (apply pair_core_id; try apply _).
    repeat (apply prod_included'; simpl; split; try apply ucmra_unit_least).
    by apply max_nat_included.
  }
  simpl.
  iAssert (▷ deq_front_at_least γtq (S d))%I as "#HDeqFront".
  {
    iDestruct "HRest" as "(_ & HH)".
    iDestruct "HH" as (? ?) "(_ & [>HDeqCtr _] & _ & _ & >%)".
    iDestruct (iterator_points_to_at_least with "HDAtLeast HDeqCtr") as "%".
    iApply (own_mono with "HFrag").

    apply auth_included. simpl. split; first done.
    repeat (apply prod_included'; simpl; split; try done).
    apply max_nat_included=>/=. lia.
  }
  iFrame.
  iIntros "!> AU !>".

  wp_pures.
  replace (_ + _)%nat with d by (rewrite Nat.mul_comm -Nat.div_mod //; lia).

  awp_apply (resume_rendezvous_spec with "HCellInv HDeqFront HArrMapsto HIsRes").
  iApply (aacc_aupd with "AU"); first done.
  iIntros (? deqFront') "(HInfArr & HCellList & HRest)".
  iAaccIntro with "HCellList".
  by iFrame; iIntros "$ !> $ !>".

  iIntros (?) "[(% & -> & #HRendFilled & HE & HCont)|HH]".
  {
    iRight.
    iExists _.
    iSplitL.
    2: by iIntros "!> HΦ !>"; wp_pures.
    iFrame "HE".
    iExists _.
    iLeft.
    iFrame. iFrame "HRendFilled".
    iSplitR; first done.
    iDestruct "HRest" as "(>% & HRest)".
    iSplitR; first done.
    iSplitR.
    {
      iPureIntro.
      intros (HDeqFront & γt & th & r & HEl).
      destruct (decide (d = (deqFront' - 1)%nat)).
      {
        subst.
        rewrite list_insert_alter in HEl.
        rewrite list_lookup_alter in HEl.
        destruct (_ !! (deqFront' - 1)%nat); simplify_eq.
      }
      rewrite list_lookup_insert_ne in HEl; try done.
      by eauto 10.
    }
    iDestruct "HRest" as (? ?) "HH".
    iExists _, _.
    by rewrite insert_length.
  }

  iDestruct "HH" as (γt th)
    "[(HEl & -> & #HRendRes & HE & HListContents & HResumerToken)|
    [(% & -> & HCanc & #HRend & HNoPerms & HE & HResTok & HListContents)|
    [(% & [-> HAwak] & HListContents)|
    (% & -> & HRendAbandoned & HE & HNoPerms & HListContents)]]]".
  4: { (* Abandoned *)
    iRight.
    iExists _.
    iSplitL.
    2: by iIntros "!> HΦ !>"; wp_pures.
    iFrame "HE".
    iExists _. iRight. iExists γt, th.
    iAssert (▷ rendezvous_thread_handle γtq γt th d)%I with "[-]" as "#HH".
    {
      iDestruct "HListContents" as "(_ & _ & _ & _ & _ & HLc)".
      iDestruct (big_sepL_lookup with "HLc") as "HCR"; first eassumption.
      simpl.
      iDestruct "HCR" as (?) "(_ & $ & _)".
    }
    iFrame "HH".
    iRight. iRight. iRight. iSplitL "HRendAbandoned".
    by iRight; iFrame.
    iSplitR; first by iPureIntro.
    iFrame "HNoPerms".
    by iFrame.
  }
  3: { (* Cancelled and we know about it. *)
    iLeft. iFrame.
    iIntros "!> AU !>". wp_pures.
    iApply ("IH" with "HAwak AU").
  }
  2: { (* Cancelled, but we don't know about it. *)
    iRight. iExists _. iFrame "HE". iSplitL.
    2: by iIntros "!> HΦ !>"; wp_pures.
    iExists _. iRight. iExists _, _. iFrame "HRend".
    iRight. iLeft. by iFrame "HCanc".
  }
  (* Resumed *)
  iRight.
  iDestruct "HEl" as %HEl.
  iExists _. iFrame "HE". iSplitL.
  2: by iIntros "!> HΦ !>"; wp_pures.
  iExists _. iRight. iExists _, _.
  iAssert (▷ rendezvous_thread_handle γtq γt th d)%I with "[-]" as "#HH".
  {
    iDestruct "HListContents" as "(_ & _ & _ & _ & _ & HLc)".
    iDestruct (big_sepL_lookup with "HLc") as "HCR".
    {
      rewrite list_insert_alter. erewrite list_lookup_alter.
      by rewrite HEl.
    }
    simpl.
    iDestruct "HCR" as (?) "(_ & $ & _)".
  }
  iFrame "HH". iClear "HH".
  iLeft.
  repeat (iSplitR; first done).

  iDestruct "HRest" as "(>% & HRest)".
  rewrite /is_thread_queue.
  rewrite insert_length.
  iFrame "HRendRes".
  iFrame.
  iPureIntro.
  intros (HLt & γt' & th' & r & HEl'').
  destruct (decide (d = (deqFront' - 1)%nat)).
  {
    subst. erewrite list_insert_alter in HEl''.
    rewrite list_lookup_alter in HEl''.
    destruct (_ !! (deqFront' - 1)%nat); simplify_eq.
  }
  rewrite list_lookup_insert_ne in HEl''; try done.
  by eauto 10.
Qed.

Theorem try_enque_thread_spec E R γa γtq γe γd γt (eℓ epℓ dℓ dpℓ: loc) (th: loc):
  is_thread_handle Nth γt #th -∗
  suspension_permit γtq -∗
  thread_doesnt_have_permits γt -∗
  <<< ∀ l deqFront, ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront >>>
  ((try_enque_thread segment_size) #th #epℓ) #eℓ @ ⊤ ∖ ↑N
  <<< ∃ (v: val),
      (∃ i (s: loc), ⌜v = SOMEV (#s, #(i `mod` Pos.to_nat segment_size)%nat)⌝ ∧
       ⌜l !! i = Some None⌝ ∧
       segment_location γa (i `div` Pos.to_nat segment_size)%nat s ∗
       rendezvous_thread_handle γtq γt th i ∗
       ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ
         (alter (fun _ => Some (cellInhabited γt th None)) i l) deqFront ∗
         inhabitant_token γtq i) ∨
      (⌜v = NONEV⌝ ∧
       ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront ∗
         thread_doesnt_have_permits γt ∗ ▷ R),
    RET v >>>.
Proof.
  iIntros "#HThLoc HSusp HNoPerms" (Φ) "AU". wp_lam. wp_pures.
  wp_lam. wp_pures.

  wp_bind (!_)%E.
  iMod "AU" as (? ?) "[(HInfArr & HListContents & >% & HRest) [HClose _]]".
  iDestruct "HRest" as (? ?) "(>[HEnqCtr HEnqPtr] & >HDeqIt & HRest)".
  iDestruct "HEnqPtr" as (? ? ?) "[#HSegLoc Hepℓ]".
  wp_load.
  iMod (iterator_counter_is_at_least with "HEnqCtr") as "[HEnqCtr #HEnqAtLeast]".
  iMod ("HClose" with "[-HSusp HNoPerms]") as "AU".
  {
    iFrame.
    iSplitR; first by iPureIntro.
    iExists _, _. iFrame.
    iExists _. iSplitR; first by iPureIntro. iExists _. by iFrame.
  }
  iModIntro.

  wp_pures.
  awp_apply iterator_value_faa. iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (cells ?) "(HInfArr & HListContents & >% & HRest)".
  iDestruct "HRest" as (senqIdx ?) "(>HEnqIt & >HDeqIt & HAwaks & >HSusps & >%)".
  iDestruct "HListContents" as "(HLC1 & HLC2 & >HAuth & HLC3)".
  iAssert (⌜(senqIdx < length cells)%nat⌝)%I as %HEnqLtLen.
  {
    rewrite /suspension_permit.
    iAssert (own γtq (◯ (S senqIdx,ε, ε))) with "[HSusp HSusps]" as "HSusp".
    {
      clear.
      iInduction senqIdx as [|enqIdx'] "IH"; first done. simpl.
      iDestruct "HSusps" as "[HSusp' HSusps]".
      change (S (S enqIdx')) with (1 ⋅ S enqIdx')%nat.
      rewrite pair_op_1 pair_op_1 auth_frag_op own_op.
      iFrame.
      iApply ("IH" with "HSusp [HSusps]").
      iClear "IH".
      by rewrite big_opL_irrelevant_element' seq_length.
    }
    iDestruct (own_valid_2 with "HAuth HSusp") as
        %[[[HValid%nat_included _]%prod_included
                                  _]%prod_included _]%auth_both_valid.
    iPureIntro.
    simpl in *.
    lia.
  }
  iMod (own_update with "HAuth") as "[HAuth HFrag]".
  2: iAssert (exists_list_element γtq senqIdx) with "HFrag" as "#HElExists".
  {
    apply auth_update_core_id; first by apply _.
    apply prod_included; simpl; split.
    by apply ucmra_unit_least.
    apply list_lookup_included.
    revert HEnqLtLen.
    clear.
    intros ? i.
    rewrite -fmap_is_map list_lookup_fmap.
    destruct (decide (i >= S senqIdx)%Z).
    {
      remember (cells !! i) as K. clear HeqK.
      rewrite lookup_ge_None_2.
      2: rewrite list_singletonM_length; lia.
      by apply option_included; left.
    }
    assert (i < length cells)%nat as HEl by lia.
    apply lookup_lt_is_Some in HEl.
    destruct HEl as [? ->]. simpl.
    destruct (decide (i = senqIdx)).
    {
      subst. rewrite list_lookup_singletonM.
      apply Some_included_total, ucmra_unit_least.
    }
    assert (forall (A: ucmraT) (i i': nat) (x: A),
                (i' < i)%nat -> list_singletonM i x !! i' = Some (ε: A))
            as HH.
    {
      clear. induction i; intros [|i']; naive_solver auto with lia.
    }
    rewrite HH. 2: lia.
    apply Some_included_total.
    apply ucmra_unit_least.
  }
  iDestruct (iterator_points_to_at_least with "HEnqAtLeast [HEnqIt]") as %HnLtn'.
  by iDestruct "HEnqIt" as "[$ _]".
  iAaccIntro with "HEnqIt".
  {
    iFrame. iIntros "HEnqIt".
    iSplitL. iSplitR; first done. iExists _, _. iFrame. done.
    by iIntros "!> $ !>".
  }
  simpl. rewrite Nat.add_1_r union_empty_r_L.
  iIntros "[[HEnqCtr HEnqPtr] HIsSus]".
  iClear "HEnqAtLeast".
  iMod (iterator_counter_is_at_least with "HEnqCtr") as "[HEnqCtr #HEnqAtLeast]".
  iClear "HFrag".
  change (own _ (◯ _)) with (iterator_issued γe senqIdx).
  iFrame.
  iSplitR "HIsSus HNoPerms".
  {
    iSplitR; first done.
    iExists _, _. simpl.
    iAssert ([∗ list] _ ∈ seq O (S senqIdx), suspension_permit γtq)%I
            with "[HSusps HSusp]" as "$".
    {
      simpl. iFrame.
      iApply (big_sepL_forall_2 with "HSusps").
      by repeat rewrite seq_length.
      done.
    }
    iFrame.
    iPureIntro. lia.
  }
  iIntros "!> AU !>".

  wp_pures. rewrite quot_of_nat.
  awp_apply (find_segment_spec with "[] HSegLoc").
  by iApply tq_cell_init.
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? ?) "[HInfArr HRest]".
  iAaccIntro with "HInfArr".
  {
    iFrame. iIntros "$ !> $ !> //".
  }
  iIntros (segId ?) "(HInfArr & #HInvs & #HSegLoc' & #HRest')".
  iAssert (⌜(senqIdx `div` Pos.to_nat segment_size <= segId)%nat⌝)%I as "%".
  by iDestruct "HRest'" as "[(% & <-)|(% & % & _)]"; iPureIntro; lia.
  iDestruct (big_sepL_lookup _ _ (senqIdx `div` Pos.to_nat segment_size)%nat with "HInvs") as "HInv".
  by apply seq_lookup; lia.
  iDestruct (cell_invariant_by_segment_invariant
               _ _ _ _ (senqIdx `mod` Pos.to_nat segment_size)%nat with "HInv") as "HInv'".
  by apply Nat.mod_upper_bound; lia.
  simpl.
  rewrite Nat.mul_comm -Nat.div_mod; try lia.
  iDestruct "HInv'" as (ℓ) "(HCellInv & >HMapsTo)".
  iFrame.
  iIntros "!> AU !>".

  wp_pures.

  destruct (decide (senqIdx `div` Pos.to_nat segment_size = segId)%nat).
  2: {
    iDestruct "HRest'" as "[[% ->]|HC]".
    {
      exfalso.
      assert (senqIdx `div` Pos.to_nat segment_size < segId)%nat by lia.
      assert ((segId * Pos.to_nat segment_size) `div` Pos.to_nat segment_size <=
              senqIdx `div` Pos.to_nat segment_size)%nat as HContra.
      by apply Nat.div_le_mono; lia.
      rewrite Nat.div_mul in HContra; lia.
    }
    iDestruct "HC" as "(% & % & HCanc)".
    rewrite segments_cancelled__cells_cancelled.
    remember (Pos.to_nat segment_size) as P.
    iAssert (cell_is_cancelled segment_size γa
              (P * senqIdx `div` P + senqIdx `mod` P)%nat) as "HCellCanc".
    {
      rewrite Nat.mul_comm.
      iApply (big_sepL_lookup with "HCanc").
      apply seq_lookup.
      assert (senqIdx `mod` P < P)%nat by (apply Nat.mod_upper_bound; lia).
      destruct (segId - senqIdx `div` P)%nat eqn:Z; try lia.
      simpl.
      lia.
    }
    rewrite -Nat.div_mod; try lia.

    wp_lam. wp_pures. wp_bind (!_)%E. (* Just so I can open an invariant. *)
    iInv N as "[[>HCancHandle _]|>HInit]" "HClose".
    by iDestruct (cell_cancellation_handle'_not_cancelled with "HCancHandle HCellCanc") as %[].
    iMod "AU" as (? ?) "[(_ & (_ & _ & >HAuth & _ & _ & HCellRRs) & _) _]".
    iDestruct (exists_list_element_lookup with "HElExists HAuth") as %[c HEl].
    destruct c as [c|]; simpl.
    2: {
      iDestruct (own_valid_2 with "HAuth HInit") as
          %[[_ HValid]%prod_included _]%auth_both_valid.
      simpl in *.
      exfalso.
      move: HValid. rewrite list_lookup_included. move=> HValid.
      specialize (HValid senqIdx). move: HValid.
      rewrite list_lookup_singletonM map_lookup HEl /= Some_included_total.
      intros HValid.
      apply prod_included in HValid; simpl in *; destruct HValid as [HValid _].
      apply prod_included in HValid; simpl in *; destruct HValid as [_ HValid].
      apply max_nat_included in HValid. simpl in *; lia.
    }
    iDestruct (big_sepL_lookup with "HCellRRs") as "HR".
    done.
    simpl.
    iDestruct "HR" as (?) "[_ HRest]".
    destruct c as [|? ? c].
    {
      iDestruct "HRest" as "(_ & >HCancHandle & _)".
      iDestruct (cell_cancellation_handle'_not_cancelled with "HCancHandle HCellCanc") as %[].
    }
    destruct c; iDestruct "HRest" as "(_ & >HIsSus' & _)".
    all: iDestruct (iterator_issued_exclusive with "HIsSus HIsSus'") as %[].
  }

  subst.
  iClear "HRest' HInvs HSegLoc HInv". clear.

  awp_apply (iterator_move_ptr_forward_spec with "[%] [$] [$]").
  by move: (Nat.mul_div_le senqIdx (Pos.to_nat segment_size)); lia.
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? ?) "(HInfArr & HListContents & HLog1 & HRest)".
  iDestruct "HRest" as (? ?) "(>HEnqIt & >HDeqIt & HAwaks & >HSusps & HLog2)".
  iCombine "HInfArr" "HEnqIt" as "HAacc".
  iAaccIntro with "HAacc".
  {
    iIntros "[$ HEnqIt]". iFrame.
    iSplitL. by iExists _, _; iFrame.
    by iIntros "!> $ !>".
  }
  iIntros "[$ EnqIt]". iFrame.
  iSplitR "HIsSus HNoPerms".
  by iExists _, _; iFrame.
  iIntros "!> AU !>".

  wp_pures. wp_lam. wp_pures.
  replace (Z.rem senqIdx _) with (Z.of_nat (senqIdx `mod` Pos.to_nat segment_size)%nat).
  2: {
    destruct (Pos.to_nat segment_size) eqn:Z; try lia.
    by rewrite rem_of_nat.
  }

  awp_apply segment_data_at_spec.
  { iPureIntro. apply Nat.mod_upper_bound; lia. }
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (? ?) "(HInfArr & HRest)".
  iDestruct (is_segment_by_location with "HSegLoc' HInfArr")
    as (? ?) "[HIsSeg HArrRestore]".
  iAaccIntro with "HIsSeg".
  {
    iIntros "HIsSeg !>".
    iDestruct ("HArrRestore" with "HIsSeg") as "$".
    iFrame.
    by iIntros "$ !>".
  }
  iIntros (?) "(HIsSeg & HArrMapsto' & _)".
  iDestruct (array_mapsto'_agree with "HArrMapsto' HMapsTo") as "->".
  iDestruct ("HArrRestore" with "[HIsSeg]") as "$"; first by iFrame.
  iFrame "HRest".
  iIntros "!> AU !>".

  wp_pures.
  awp_apply (inhabit_cell_spec with "[$] HNoPerms HIsSus HElExists HMapsTo HCellInv").
  iApply (aacc_aupd_commit with "AU"); first done.
  iIntros (? deqFront) "(HInfArr & HListContents & HRest)".
  iAaccIntro with "HListContents".
  { iIntros "$"; iFrame. iIntros "!> $ !>". done. }
  iIntros (?) "H".
  iDestruct "H" as "[(% & -> & HInhToken & #HRend & HListContents')|
    (% & -> & HNoPerms & HR & HListContents)]".
  all: iExists _; iSplitL; [|iIntros "!> HΦ !>"; by wp_pures].
  2: {
    iRight. iSplitR; first done. by iFrame.
  }
  iLeft.
  iExists _, _. iSplitR; first done. iSplitR; first done.
  iFrame "HInhToken HSegLoc' HRend".
  iDestruct "HRest" as "(>% & >HRest)".
  rewrite /is_thread_queue.
  rewrite alter_length.
  iFrame "HInfArr HRest HListContents'".
  rewrite /cell_invariant.
  iPureIntro.
  intros (HLt & γt' & th' & r & HEl).
  destruct (decide (senqIdx = (deqFront - 1)%nat)).
  {
    subst. rewrite list_lookup_alter in HEl.
    destruct (_ !! (deqFront - 1)%nat); simpl in *; discriminate.
  }
  rewrite list_lookup_alter_ne in HEl; eauto 10.
Qed.

Theorem new_thread_queue_spec S R:
  {{{ True }}}
    new_thread_queue segment_size #()
  {{{ γa γtq γe γd eℓ epℓ dℓ dpℓ, RET ((#epℓ, #eℓ), (#dpℓ, #dℓ));
      is_thread_queue S R γa γtq γe γd eℓ epℓ dℓ dpℓ [] 0 }}}.
Proof.
  iIntros (Φ) "_ HPost".
  wp_lam.
  iMod (own_alloc (● (GSet (set_seq 0 0), MaxNat 0))) as (γd) "HAuthD".
  { simpl. apply auth_auth_valid, pair_valid; split; done. }
  iMod (own_alloc (● (GSet (set_seq 0 0), MaxNat 0))) as (γe) "HAuthE".
  { simpl. apply auth_auth_valid, pair_valid; split; done. }
  iMod (own_alloc (● (0%nat, (0%nat, MaxNat 0), []))) as (γtq) "HAuth".
  { apply auth_auth_valid, pair_valid; split; try done.
    apply list_lookup_valid; intro. rewrite lookup_nil //. }
  iMod (own_alloc (● [])) as (γa) "HAuthTq".
  { simpl. apply auth_auth_valid, list_lookup_valid. intros i.
    by rewrite lookup_nil. }
  wp_apply (new_infinite_array_spec with "[HAuthTq]").
  by iFrame; iApply (tq_cell_init γtq γd).
  iIntros (ℓ) "[HInfArr #HSegLoc]".
  wp_pures.

  rewrite -wp_fupd.
  wp_alloc eℓ as "Heℓ". wp_alloc dℓ as "Hdℓ".
  wp_alloc epℓ as "Hepℓ". wp_alloc dpℓ as "Hdpℓ".

  wp_pures.
  iApply "HPost".
  rewrite /is_thread_queue /cell_list_contents /cell_list_contents_auth_ra /=.
  iFrame "HInfArr HAuth".
  repeat iSplitR; try done.
  by iPureIntro; lia.

  iExists 0%nat, 0%nat. simpl.
  rewrite /iterator_points_to /iterator_counter.
  iFrame "Hepℓ Hdpℓ HAuthE HAuthD".
  iSplitL "Heℓ".
  {
    iExists 0%nat. simpl.
    iSplitR; first done.
    iExists _; by iFrame.
  }
  iSplitL "Hdℓ".
  {
    iExists 0%nat. simpl.
    iSplitR; first done.
    iExists _; by iFrame.
  }
  eauto.
Qed.

Theorem cancel_cell_spec (s: loc) (i: nat) E R γa γtq γe γd eℓ epℓ dℓ dpℓ:
  rendezvous_cancelled γtq i -∗
  segment_location γa (i `div` Pos.to_nat segment_size) s -∗
  canceller_token γtq i -∗
  <<< ∀ l deqFront, ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront >>>
      cancel_cell segment_size (#s, #(i `mod` Pos.to_nat segment_size)%nat)%V @ ⊤
  <<< ∃ (v: bool), ∃ γt th, if v
        then ⌜l !! i = Some (Some (cellInhabited γt th (Some (cellCancelled None))))⌝ ∧
             ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ
             (<[i := Some (cellInhabited γt th (Some (cellCancelled (Some cancellationFinished))))]> l) deqFront
        else ⌜l !! i = Some (Some (cellInhabited γt th (Some (cellCancelled (Some cancellationPrevented)))))⌝ ∧
             ▷ is_thread_queue E R γa γtq γe γd eℓ epℓ dℓ dpℓ l deqFront ∗
             ▷ awakening_permit γtq, RET #v >>>.
Proof.
  iIntros "#HRendCanc #HSegLoc HCancTok" (Φ) "AU".
  wp_lam. wp_pures. wp_lam. wp_pures.

  awp_apply (segment_data_at_spec) without "HCancTok".
  by iPureIntro; apply Nat.mod_upper_bound; lia.
  iApply (aacc_aupd_abort with "AU"); first done.
  iIntros (l deqFront) "HTq".
  iDestruct "HTq" as "[HInfArr HTail']".
  iDestruct (is_segment_by_location with "HSegLoc HInfArr")
    as (? ?) "[HIsSeg HInfArrRestore]".
  iAaccIntro with "HIsSeg".
  {
    iIntros "HIsSeg".
    iDestruct ("HInfArrRestore" with "HIsSeg") as "HInfArr".
    iIntros "!>". iSplitL; last by iIntros "$".
    by iFrame.
  }
  iIntros (ℓ) "(HIsSeg & #HArrMapsto & #HCellInv)".
  iDestruct (bi.later_wand with "HInfArrRestore HIsSeg") as "$".
  iFrame.
  iIntros "!> AU !> HCancTok". wp_pures.

  awp_apply getAndSet.getAndSet_spec. clear.
  iApply (aacc_aupd with "AU"); first done.
  iIntros (l n) "(HInfArr & HListContents & HTail')".
  iAssert (▷ ⌜∃ γt th r, l !! i = Some (Some (cellInhabited γt th
                              (Some (cellCancelled r))))⌝)%I
          as "#>HEl".
  {
    iDestruct "HListContents" as "(_ & _ & >HAuth & _)".
    iDestruct (own_valid_2 with "HAuth HRendCanc")
      as %[[_ (x' & HLookup & HInc)%list_singletonM_included]%prod_included
                                                             _]%auth_both_valid.
    iPureIntro.
    rewrite map_lookup /= in HLookup.
    destruct (l !! i) as [el|] eqn:HLookup'; simpl in *; simplify_eq.
    apply prod_included in HInc. destruct HInc as [HInc _]. simpl in HInc.
    apply prod_included in HInc. destruct HInc as [_ HInc]. simpl in HInc.
    apply max_nat_included in HInc.
    destruct el as [[|γt th [[r| |]|]]|]; simpl in HInc; try lia.
    by eauto.
  }
  iDestruct "HEl" as %(γt & th & r & HEl).

  iDestruct (cell_list_contents_lookup_acc with "HListContents")
    as "[HRR HListContentsRestore]"; first done.
  simpl.
  iDestruct "HRR" as (ℓ') "(#>HArrMapsto' & HRendHandle & HIsSus & >HInhTok & HH)".
  iDestruct (array_mapsto'_agree with "HArrMapsto' HArrMapsto") as %->.
  assert (⊢ inhabitant_token' γtq i (1/2)%Qp -∗
            inhabitant_token' γtq i (1/2)%Qp -∗
            inhabitant_token' γtq i (1/2)%Qp -∗ False)%I as HNoTwoCanc.
  {
    iIntros "HInhTok1 HInhTok2 HInhTok3".
    iDestruct (own_valid_3 with "HInhTok1 HInhTok2 HInhTok3") as %HValid.
    iPureIntro.
    move: HValid. rewrite -auth_frag_op -pair_op.
    repeat rewrite list_singletonM_op.
    rewrite auth_frag_valid /=. rewrite pair_valid.
    rewrite list_singletonM_valid. intros [_ [[[[HPairValid _] _] _] _]].
    by compute.
  }
  destruct r as [[|]|].
  {
    iDestruct "HH" as "[> HCancTok' _]".
    by iDestruct (HNoTwoCanc with "HInhTok HCancTok HCancTok'") as %[].
  }
  {
    iDestruct "HH" as "[HIsRes [(Hℓ & HCancHandle & HAwak)|(_ & >HCancTok' & _)]]".
    2: by iDestruct (HNoTwoCanc with "HInhTok HCancTok HCancTok'") as %[].
    iAssert (▷ ℓ ↦ RESUMEDV ∧ ⌜val_is_unboxed RESUMEDV⌝)%I with "[$]" as "HAacc".
    iAaccIntro with "HAacc".
    {
      iIntros "[Hℓ _]". iFrame "HCancTok".
      iIntros "!>".
      iSplitL; last by iIntros "$". iFrame.
      iApply "HListContentsRestore".
      iExists _. iFrame "HArrMapsto' HRendHandle HIsSus HInhTok".
      iFrame "HIsRes". iLeft. iFrame.
    }

    iIntros "Hℓ !>". iRight. iExists false.
    iSplitL.
    {
      iExists γt, th. iSplitR; first done. iFrame "HAwak".
      iFrame. iApply "HListContentsRestore".
      iExists _. iFrame "HArrMapsto' HRendHandle HIsSus HInhTok".
      iFrame "HIsRes". iRight. iFrame.
    }
    iIntros "HΦ' !>". wp_pures.
    by iApply "HΦ'".
  }

  iDestruct "HH" as "(Hℓ & HE & HCancHandle & HNoPerms & HAwak)".

  iAssert (▷ ℓ ↦ InjLV #th ∧ ⌜val_is_unboxed (InjLV #th)⌝)%I with "[$]" as "HAacc".

  iAaccIntro with "HAacc".
  {
    iIntros "[Hℓ _]". iFrame "HCancTok".
    iIntros "!>".
    iSplitL; last by iIntros "$ !>".
    iFrame.
    iApply "HListContentsRestore".
    iExists _. iFrame "HArrMapsto' HRendHandle HIsSus HInhTok".
    iFrame.
  }

  iIntros "Hℓ !>".
  iRight. iExists true. iSplitL.
  {
    iExists γt, th. iSplitR; first done.
  }
  iSplitR "HCancHandle".
  {
    iFrame.
    iApply "HListContentsRestore".
    iExists _. iFrame "HArrMapsto' HRendHandle HIsSus HInhTok".
    iFrame.
    iRight. iRight. iFrame. iRight. iFrame.
  }
  iIntros "AU !>". wp_pures.

  awp_apply (segment_cancel_cell_spec with "HSegLoc HCancHandle").
  by apply Nat.mod_upper_bound; lia.

  iApply (aacc_aupd_commit with "AU"); first done.
  iIntros (? ?) "(HInfArr & HTail')".
  iAaccIntro with "HInfArr".
  { iIntros "$ !>". iFrame. iIntros "$ !> //". }
  iIntros (?) "$ !>". iExists true. iFrame.
  iSplitR; first by iRight.
  iIntros "HΦ !>". wp_pures. by iApply "HΦ".
Qed.

End proof.