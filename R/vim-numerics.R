vim_numerics =
  function(Y,
           numerics,
           factors,
           V,
           folds,
           A_names,
           family,
           minCell,
           minYs,
           Q.library,
           g.library,
           Qbounds,
           corthres,
           adjust_cutoff,
           verbose = FALSE,
           verbose_tmle = FALSE,
           verbose_reduction = FALSE) {
  # TODO: move out.
  cor.two = function(x, y) {
    (stats::cor(na.omit(cbind(x, y)))[1, 2])^2
  }

  # We use && so that the second check will be skipped when num_numeric == 0.
  if (numerics$num_numeric > 0 && ncol(numerics$data.cont.dist) > 0) {
    cat("Estimating variable importance for", numerics$num_numeric, "numerics.\n")

    xc = ncol(numerics$data.cont.dist)
    names.cont = colnames(numerics$data.cont.dist)
    n.cont = nrow(numerics$data.cont.dist)

    # Tally the number of unique values (bins) in each numeric variable; save as a vector.
    numcat.cont = apply(numerics$data.cont.dist, 2, length_unique)

    cats.cont = lapply(1:xc, function(i) {
      sort(unique(numerics$data.cont.dist[, i]))
    })

    ### Loop over each numeric variable.
    # Define var_i just to avoid automated NOTEs, will be overwritten by foreach.
    var_i = NULL
    #vim_numeric = foreach::foreach(var_i = 1:num_numeric, .verbose = verbose,
    #                               .errorhandling = "stop") %do_op% {
    vim_numeric = future.apply::future_lapply(1:numerics$num_numeric, future.seed = TRUE,
                                        function(var_i) {
    #vim_numeric = lapply(1:num_numeric, function(var_i) {
      nameA = names.cont[var_i]

      if (verbose) cat("i =", var_i, "Var =", nameA, "out of", xc, "numeric variables\n")

      if (!nameA %in% A_names) {
        if (verbose) cat("Skipping", nameA, " as it is not in A_names.\n")
        return(NULL)
      }

      #for (fold_k in 1:V) {
      # This is looping sequentially for now.
      #fold_results = foreach (fold_k = 1:V) %do% {
      # TODO: convert to future_lapply
      fold_results = lapply(1:V, function(fold_k) {
        if (verbose) cat("Fold", fold_k, "of", V, "\n")

        # data.cont.dist is the discretized version of the numeric variables of size bins_numeric
        At = numerics$data.cont.dist[folds != fold_k, var_i]
        Av = numerics$data.cont.dist[folds == fold_k, var_i]
        Yt = Y[folds != fold_k]
        Yv = Y[folds == fold_k]

        # Create a list to hold the results we calculate in this fold.
        # Set them to default values and update as they are calculated.
        fold_result = list(
          # Set failed = FALSE at the very end if everything works.
          failed = TRUE,
          # Message should report on the status for this fold.
          message = "",
          obs_training = length(Yt),
          obs_validation = length(Yv),
          error_count = 0,
          # Results for estimating the maximum level / treatment.
          level_max = list(
            # Level is which bin was chosen.
            level = NULL,
            # Label is the string description of that bin.
            label = NULL,
            # val_preds contains the g, Q, and H predictions on the validation data.
            val_preds = NULL,
            # Estimate of EY on the training data.
            estimate_training = NULL,
            # Risk from SuperLearner on Q.
            risk_Q = NULL,
            # Risk from SuperLearner on g.
            risk_g = NULL
          )
        )
        # Copy the blank result to a second element for the minimum level/bin.
        fold_result$level_min = fold_result$level_max

        # Conduct penalized histogramming by looking at the distribution of the rare outcome over
        # the treatment variable. So we create A_Y1 as the conditional distribution of treatment given Y = 1.
        # P(A | Y = 1).
        if (length(unique(Yt)) == 2L) {
          # Binary outcome.

          A_Y1 = At[Yt == 1 & !is.na(At)]

          # Check if AY1 has only a single value. If so, skip histogramming to avoid an error.
          singleAY1 = length(unique(na.omit(A_Y1))) == 1L
        } else {
          # Continuous outcome - just restricted to non-missing treatment.
          A_Y1 = At[!is.na(At)]
          singleAY1 = F
        }

        if (!singleAY1) {
          # Within this CV-TMLE fold look at further combining bins of the treatment based on the
          # penalized histogram.
          # Note that this is only examining the already discretized version of the treatment variable.
          penalized_hist = histogram::histogram(A_Y1, verbose = F, type = "irregular", plot = F)
          hh = penalized_hist$breaks

          # TODO: see if these next two steps are ever used/needed.

          # Check if the final cut-off is less that the maximum possible level; if so extend to slightly
          # larger than the maximimum possible level.
          if (hh[length(hh)] < max(At, na.rm = TRUE)) {
            hh[length(hh)] = max(At, na.rm = TRUE) + 0.1
          }

          # Check if the lowest cut-off is greater than the minimum possible bin; if so extend to slightly
          # below the minimum level.
          if (hh[1] > min(At[At > 0], na.rm = TRUE)) {
            hh[1] = min(At[At > 0], na.rm = TRUE) - 0.1
          }

          # Re-bin the training and validation vectors for the treatment variable based on the penalized
          # histogram.
          # This is creating factors, with levels specific to this CV-TMLE fold.
          Atnew = cut(At, breaks = hh)
          Avnew = cut(Av, breaks = hh)

          # TODO: check if the binning results in no-variation, and handle separately from the below situation.

        }
        if (singleAY1 || length(na.omit(unique(Atnew))) <= 1 ||
            length(na.omit(unique(Avnew))) <= 1) {
          error_msg = paste("Skipping", nameA, "in this fold because there is no variation.")
          if (verbose) cat(error_msg, "\n")
          fold_result$message = error_msg
          #warning(error_msg)
        } else {

          # These labels are simply the quantiles right now.
          At_bin_labels = names(table(Atnew))

          # Non-discretized version of A in the training data; converted to a vector.
          At_raw = numerics$data.num[folds != fold_k, var_i]

          # Loop over the Atnew levels and figure out the equivalent true range of this bin
          # by examining the non-discretized continuous variable.
          for (newlevel_i in 1:length(unique(as.numeric(na.omit(Atnew))))) {
            range = range(na.omit(At_raw[na.omit(which(as.numeric(Atnew) == newlevel_i))]))
            label_i = paste0("[", round(range[1], 2), ", ", round(range[2], 2), "]")
            At_bin_labels[newlevel_i] = label_i
          }
          At_bin_labels

          Atnew = as.numeric(Atnew) - 1
          Avnew = as.numeric(Avnew) - 1

          # Update the number of bins for this numeric variable.
          # CK: note though, this is specific to this CV-TMLE fold - don't we
          # need to differentiate which fold we're in?
          numcat.cont[var_i] = length(At_bin_labels)

          # change this to match what was done for factors - once
          # cats.cont[[i]]=as.numeric(na.omit(unique(Atnew)))
          cats.cont[[var_i]] = as.numeric(names(table(Atnew)))

          ### acit.numW is just same as data.cont.dist except with NA's replaced by
          ### 0's.
          # TODO: cbind iteratively to create W matrix below, so that we don't
          # need these extra NA vectors.
          if (is.null(numerics$miss.cont)) {
            numerics$miss.cont = rep(NA, n.cont)
          }
          if (is.null(factors$miss.fac)) {
            factors$miss.fac = rep(NA, n.cont)
          }
          if (is.null(factors$datafac.dumW)) {
            factors$datafac.dumW = rep(NA, n.cont)
          }
          if (is.null(numerics$data.numW)) {
            numerics$data.numW = rep(NA, n.cont)
          }

          # Construct a matrix of adjustment variables in which we use the imputed dataset
          # but remove the current treatment variable.
          W = data.frame(numerics$data.numW[, -var_i, drop = FALSE],
                         numerics$miss.cont,
                         factors$datafac.dumW,
                         factors$miss.fac)

          # Remove any columns in which all values are NA.
          # CK: but we're using imputed data, so there should be no NAs actually.
          # (With the exception of the NA vectors possibly added above.
          W = W[, !apply(is.na(W), 2, all), drop = FALSE]

          # Separate adjustment matrix into the training and test folds.
          Wt = W[folds != fold_k, , drop = FALSE]
          Wv = W[folds == fold_k, , drop = FALSE]

          # Identify the missingness indicator for this treatment.
          miss_ind_name = paste0("Imiss_", nameA)

          # Remove the missingness indicator for this treatment (if it exists) from the adjustment set.
          Wt = Wt[, colnames(Wt) != miss_ind_name, drop = FALSE]
          Wv = Wv[, colnames(Wt) != miss_ind_name, drop = FALSE]

          # Pull out any variables that are overly correlated with At (corr coef > corthes)

          # Suppress possible warning from cor() "the standard deviation is zero".
          # TODO: remove those constant variables beforehand?
          suppressWarnings({
            corAt = apply(Wt, 2, cor.two, y = At)
          })


          keep_vars = corAt < corthres & !is.na(corAt)

          if (verbose && sum(!keep_vars) > 0) {
            cat("Removed", sum(!keep_vars), "columns based on correlation threshold", corthres, "\n")
          }

          Wv = Wv[, keep_vars, drop = FALSE]
          Wt = Wt[, keep_vars, drop = FALSE]

          if (verbose) {
            cat("Columns:", ncol(Wt))
            if (!is.null(adjust_cutoff)) cat(" Reducing dimensions to", adjust_cutoff)
            cat("\n")
          }

          # Use HOPACH to reduce dimension of W to some level of tree.
          reduced_results = reduce_dimensions(Wt, Wv, adjust_cutoff, verbose = verbose_reduction)

          Wtsht = reduced_results$data
          Wvsht = reduced_results$newX

          # Identify any constant columns.
          is_constant = sapply(Wtsht, function(col) var(col) == 0)
          is_constant = is_constant[is_constant]

          if (verbose) {
            cat("Updated ncols -- training:", ncol(Wtsht), "test:", ncol(Wvsht), "\n")
            # Restrict to true elements.
            if (length(is_constant) > 0L) {
              cat("Constant columns (", length(is_constant), "):\n")
              print(is_constant)
            }
          }

          # Indicator that Y and A are both defined.
          deltat = as.numeric(!is.na(Yt) & !is.na(Atnew))
          deltav = as.numeric(!is.na(Yv) & !is.na(Avnew))

          # TODO: may want to remove this procedure, which is pretty arbitrary.
          if (sum(deltat == 0) < 10L) {
            Yt = Yt[deltat == 1]
            Wtsht = Wtsht[deltat == 1, , drop = FALSE]
            Atnew = Atnew[deltat == 1]
            deltat = deltat[deltat == 1]
          }

          vals = cats.cont[[var_i]]
          num.cat = length(vals)

          Atnew[is.na(Atnew)] = -1
          Avnew[is.na(Avnew)] = -1

          if ((length(is_constant) > 0 && mean(is_constant) == 1) ||
              (length(unique(Yt)) == 2L && min(table(Avnew[Avnew >= 0], Yv[Avnew >= 0])) <= minCell)) {
            if (length(is_constant) > 0 && mean(is_constant) == 1) {
              error_msg = paste("Skipping", nameA, "because HOPACH reduced W",
                "to all constant columns.")
            } else {
              error_msg = paste("Skipping", nameA, "due to minCell constraint.\n")
            }
            if (T || verbose) cat(error_msg)
            fold_result$message = error_msg
            # warning(error_msg)
            # Go to the next loop iteration.
            #next
          } else {
            # CK TODO: this is not exactly the opposite of the IF above. Is that intentional?
            #if (length(unique(Yt)) > 2 || min(table(Avnew, Yv)) > minCell) {

            # Tally how many bins fail with an error.
            error_count = 0

            if (verbose) cat("Estimating training TMLEs", paste0("(", numcat.cont[var_i], " bins)"))

            training_estimates = list()

            # Loop over each bin for this variable.
            for (j in 1:numcat.cont[var_i]) {

              # Create a treatment indicator, where 1 = obs in this bin
              # and 0 = obs not in this bin.
              IA = as.numeric(Atnew == vals[j])

              # CV-TMLE: we are using this for three reasons:
              # 1. Estimate Y_a on training data.
              # 2. Estimate Q on training data.
              # 3. Estimate g on training data.
              tmle_result = try(estimate_tmle2(Yt, IA, Wtsht, family, deltat,
                                               Q.lib = Q.library,
                                               # Pass in Q bounds from the full
                                               # range of Y (training & test).
                                               Qbounds = Qbounds,
                                               g.lib = g.library, verbose = verbose_tmle),
                                silent = !verbose)

              # Old way:
              #res = try(estimate_tmle(Yt, IA, Wtsht, family, deltat, Q.lib = Q.library,
              #                        g.lib = g.library, verbose = verbose), silent = T)

              if (class(tmle_result) == "try-error") {
                # Error.
                if (verbose) cat("X")
                error_count = error_count + 1
              } else {

                # TMLE succeeded (hopefully).

                # Save bin label.
                tmle_result$label = At_bin_labels[j]

                training_estimates[[j]] = tmle_result

                if (verbose) cat(".")
              }
            }
            # Finished looping over each level of the assignment variable.
            if (verbose) cat(" done.\n")

            fold_result$error_count = error_count

            # Extract theta estimates.
            theta_estimates = sapply(training_estimates, function(result) {
              # Handle errors in the tmle estimation by returning NA.
              ifelse("theta" %in% names(result), result$theta, NA)
            })

            # Identify maximum EY1 (theta)
            maxj = which.max(theta_estimates)

            # Identify minimum EY1 (theta)
            minj = which.min(theta_estimates)

            if (verbose) {
              cat("Max level:", vals[maxj], At_bin_labels[maxj], paste0("(", maxj, ")"),
                  "Min level:", vals[minj], At_bin_labels[minj], paste0("(", minj, ")"), "\n")
            }

            # Save that estimate.
            maxEY1 = training_estimates[[maxj]]$theta
            labmax = vals[maxj]

            # Save these items into the fold_result list.
            fold_result$level_max$level = maxj
            fold_result$level_max$estimate_training = maxEY1
            #fold_result$level_max$label = labmax
            fold_result$level_max$label = At_bin_labels[maxj]

            # Save the Q risk for the discrete SuperLearner.
            # We don't have the CV.SL results for the full SuperLearner as it's too
            # computationallity intensive.
            fold_result$level_max$risk_Q =
              training_estimates[[maxj]]$q_model$cvRisk[
                which.min(training_estimates[[maxj]]$q_model$cvRisk)]
            # And the g's discrete SL risk.
            fold_result$level_max$risk_g =
              training_estimates[[maxj]]$g_model$cvRisk[
                which.min(training_estimates[[maxj]]$g_model$cvRisk)]


            minEY1 = training_estimates[[minj]]$theta
            labmin = vals[minj]

            # Save these items into the fold_result list.
            fold_result$level_min$level = minj
            fold_result$level_min$estimate_training = minEY1
            #fold_result$level_min$label = labmin
            fold_result$level_min$label = At_bin_labels[minj]

            # Save the Q risk for the discrete SuperLearner.
            # We don't have the CV.SL results for the full SuperLearner as it's too
            # computationallity intensive.
            fold_result$level_min$risk_Q =
              training_estimates[[minj]]$q_model$cvRisk[
                which.min(training_estimates[[minj]]$q_model$cvRisk)]
            # And the g's discrete SL risk.
            fold_result$level_min$risk_g =
              training_estimates[[minj]]$g_model$cvRisk[
                which.min(training_estimates[[minj]]$g_model$cvRisk)]

            # This fold failed if we got an error for each category
            # Or if the minimum and maximum bin is the same.
            if (error_count == numcat.cont[var_i] || minj == maxj) {
              message = paste("Fold", fold_k, "failed,")
              if (error_count == numcat.cont[var_i]) {
                message = paste(message, "all", num.cat, "levels had errors.")
              } else {
                message = paste(message, "min and max level are the same. (j = ", minj,
                                "label = ", training_estimates[[minj]]$label, ")")
              }
              fold_result$message = message

              if (verbose) {
                cat(message, "\n")
              }
            } else {

              # Turn to validation data.

              # Estimate minimum level (control).

              # Indicator for having the desired control bin on validation.
              IA = as.numeric(Avnew == vals[minj])

              # Missing values are not taken to be in this level.
              IA[is.na(IA)] = 0

              if (verbose) cat("\nMin level prediction - apply_tmle_to_validation()\n")

              # CV-TMLE: predict g, Q, and clever covariate on validation data.
              min_preds = try(apply_tmle_to_validation(Yv, IA, Wvsht, family,
                                                       deltav, training_estimates[[minj]],
                                                       verbose = verbose))

              # Old version:
              #res = try(estimate_tmle(Yv, IA, Wvsht, family, deltav,
              #                        Q.lib = Q.library,
              #                        g.lib = g.library, verbose = verbose),
              #          silent = T)

              if (class(min_preds) == "try-error") {
                message = paste("CV-TMLE prediction on validation failed during",
                                "low/control level.")
                fold_result$message = message
                if (verbose) cat(message, "\n")
              } else {
                # Save the result.
                fold_result$level_min$val_preds = min_preds

                # Switch to maximum level (treatment).

                # Indicator for having the desired treatment bin on validation
                IA = as.numeric(Avnew == vals[maxj])

                # Missing values are not taken to be in this level.
                IA[is.na(IA)] = 0

                if (verbose) cat("\nMax level prediction - apply_tmle_to_validation()\n")

                # CV-TMLE: predict g, Q, and clever covariate on validation data.

                max_preds = try(apply_tmle_to_validation(Yv, IA, Wvsht, family,
                                                         deltav, training_estimates[[maxj]],
                                                         verbose = verbose))
                # Old code:
                #res2 = try(estimate_tmle(Yv, IA, Wvsht, family, deltav,
                #                         Q.lib = Q.library,
                #                         g.lib = g.library, verbose = verbose),
                #           silent = !verbose)


                if (class(max_preds) == "try-error") {
                  message = paste("CV-TMLE prediction on validation failed",
                                  "during high/treatment level.")
                  fold_result$message = message
                  if (verbose) cat(message, "\n")
                } else {
                  # Save the result.
                  fold_result$level_max$val_preds = max_preds
                  fold_result$message = "Succcess"
                  fold_result$failed = FALSE
                }
              }
            }
          }
        }
        if (verbose) cat("Completed fold", fold_k, "\n\n")

        # Return results for this fold.
        fold_result
      }) # End lapply
      # Done looping over each fold.

      # Create list to save results for this variable.
      var_results = list(
        EY1V = NULL,
        EY0V = NULL,
        thetaV = NULL,
        varICV = NULL,
        labV = NULL,
        nV = NULL,
        fold_results = fold_results,
        type = "factor",
        name = nameA
      )


      # TODO: compile results into the new estimate.

      # if (verbose) cat("Estimating pooled min.\n")
      pooled_min = estimate_pooled_results(lapply(fold_results, function(x) x$level_min),
                                           verbose = verbose)
      # if (verbose) cat("Estimating pooled max.\n")
      pooled_max = estimate_pooled_results(lapply(fold_results, function(x) x$level_max),
                                           verbose = verbose)

      var_results$EY0V = pooled_min$thetas
      var_results$EY1V = pooled_max$thetas
      if (length(var_results$EY1V) == length(var_results$EY0V)) {
        var_results$thetaV = var_results$EY1V - var_results$EY0V
      } else {
        if (verbose) {
          cat("Error: EY1V and EY0V are different lengths. EY1V =",
              length(var_results$EY1V), "EY0V =", length(var_results$EY0V), "\n")
        }
        var_results$thetaV = rep(NA, max(length(var_results$EY1V),
                                         length(var_results$EY0V)))
      }


      # Save how many observations were in each validation fold.
      var_results$nV = sapply(fold_results, function(x) x$obs_validation)

      # Combine labels into a two-column matrix.
      # First column is min and second is max.
      # TODO: not sure if data structure for this part is correct.
      labels = do.call(rbind,
                       lapply(fold_results, function(x) c(x$level_min$label, x$level_max$label)))

      var_results$labV = labels

      # If either of the thetas is null it means that all CV-TMLE folds failed.
      if (!is.null(pooled_min$thetas)) {

        # Influence_curves here is a list, with each element a set of results.
        var_results$varICV = sapply(1:V, function(index) {
          if (length(pooled_max$influence_curves) >= index &&
              length(pooled_min$influence_curves) >= index) {
            var(pooled_max$influence_curves[[index]] - pooled_min$influence_curves[[index]])
          } else {
            NA
          }
        })


        if (verbose) {
          signif_digits = 4
          ey0_mean = mean(pooled_min$thetas)
          if (is.numeric(ey0_mean)) {
            cat("[Min] EY0:", signif(ey0_mean, signif_digits))
            if (is.numeric(pooled_min$epsilon)) {
              cat(" Epsilon:", signif(pooled_min$epsilon, signif_digits), "\n")
            }
          }

          ey1_mean = mean(pooled_max$thetas)
          if (is.numeric(ey1_mean)) {
            cat("[Max] EY1:", signif(ey1_mean, signif_digits))
            if (is.numeric(pooled_max$epsilon)) {
              cat(" Epsilon:", signif(pooled_max$epsilon, signif_digits), "\n")
            }
          }

          cat("ATEs:", signif(var_results$thetaV, signif_digits), "\n")
          cat("Variances:", signif(var_results$varICV, signif_digits), "\n")
          cat("Labels:\n")
          print(labels)
          cat("\n")
        }

      }

      # Return results for this factor variable.
      var_results
    #} # end foreach loop.
    }) # End lapply or future_lapply if we're not using foreach

    if (verbose) cat("Numeric VIMs:", length(vim_numeric), "\n")

    # Confirm that we have the correct number of results, otherwise fail out.
    if (length(vim_numeric) != numerics$num_numeric) {
      # TODO: remove this.
      save(vim_numeric, file = "varimpact.RData")
      # TEMP remove this:
      stop(paste("We have", numerics$num_numeric, "continuous variables but only",
                 length(vim_numeric), "results."))
    }

    colnames_numeric = colnames(numerics$data.cont.dist)
  } else {
    colnames_numeric = NULL
    vim_numeric = NULL
    cat("No numeric variables for variable importance estimation.\n")
  }

  if (verbose) cat("Completed numeric variable importance estimation.\n")

  # Compile and return results.
  (results = list(
    vim_numeric = vim_numeric,
    colnames_numeric = colnames_numeric
    #, data.numW = numerics$data.numW
  ))
}